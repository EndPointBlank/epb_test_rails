# frozen_string_literal: true

require "json"
require "socket"

# A real HTTP server, on a real loopback socket, standing in for intake.
#
# Deliberately NOT a stub of the SDK's command objects. Every bug the
# authenticate path carried lived between the guard and the wire: a guard that
# named a command this gem has never contained, a guard that parsed the body
# before checking there was one, and a guard that dropped the status intake
# answered with. Replacing `BasicAuthenticate.authenticate` with a double
# replaces exactly the code under test, and all three sail through green. So the
# SDK is pointed at this server and makes a genuine HTTP request to it.
#
# Both guards post to the same place -- `Configuration#authorize_url`, which is
# `"#{base_url}/api/authorize"` -- so one server serves the authenticate route
# and the authorize route, and the parity test can hold intake's answer
# genuinely identical between them rather than approximately identical.
class StubIntake
  AUTHORIZE_PATH = "/api/authorize"

  # Enough of a reason phrase to be readable in a packet capture. Excon reads
  # the numeric status and ignores this, so an unlisted status is not a
  # problem -- it just reads as "Status".
  REASONS = {
    200 => "OK",
    201 => "Created",
    401 => "Unauthorized",
    403 => "Forbidden",
    418 => "I'm a teapot",
    500 => "Internal Server Error",
    502 => "Bad Gateway",
    503 => "Service Unavailable"
  }.freeze

  # What intake sends when it grants the call. `authorize!` reads
  # `data[0]['source_application_environment_id']` out of this and puts it in
  # the Rack env, so a granted authorize request needs the real shape or it
  # fails after the guard for an unrelated reason.
  GRANTED_BODY = { "data" => [ { "source_application_environment_id" => "app-env-test" } ] }.freeze

  Call = Struct.new(:path, :headers, :body, keyword_init: true)

  attr_reader :port

  def initialize(status: 201, body: nil, content_type: "application/json")
    @status = status
    @body = body || GRANTED_BODY.to_json
    @content_type = content_type
    @calls = []
    @mutex = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { accept_loop }
  end

  def base_url
    "http://127.0.0.1:#{@port}"
  end

  # Only the authorize calls. The SDK's log writers run on a background thread
  # and post request/response rows to `log_base_url`, which these tests leave
  # pointed where it already pointed; filtering by path means a stray write
  # could never be miscounted as a guard asking intake a question.
  def authorize_calls
    @mutex.synchronize { @calls.select { |call| call.path == AUTHORIZE_PATH } }
  end

  def stop
    @thread&.kill
    @server.close unless @server.closed?
  rescue IOError
    nil
  end

  # A port with nothing listening on it: bound long enough to be certain it is
  # free, then released. A connection there is refused immediately, so "intake
  # did not answer" is a real transport failure -- the same `Excon::Error` the
  # SDK swallows into a nil response -- without the test sitting through a
  # genuine connect timeout.
  def self.unreachable_base_url
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    "http://127.0.0.1:#{port}"
  end

  # Points the SDK at a stub intake answering `status`/`body` for the duration
  # of the block, and hands the block the server so it can be interrogated.
  #
  # Only `base_url` is overridden. `log_base_url` is left alone deliberately:
  # the writers memoize their URL at singleton construction, so moving it here
  # would not redirect them anyway, and leaving it keeps the stub's call log to
  # guard traffic only.
  def self.serving(status: 201, body: nil, content_type: "application/json")
    intake = new(status: status, body: body, content_type: content_type)
    with_base_url(intake.base_url) { yield intake }
  ensure
    intake&.stop
  end

  def self.with_base_url(url)
    configuration = EndPointBlank::Configuration.instance
    previous = configuration.instance_variable_get(:@base_url)
    configuration.base_url = url
    # `authorize!` caches a 201 per credential/route/method/version, so an
    # answer from one example could otherwise decide the next one.
    EndPointBlank::Commands::AuthenticationCache.instance.clear
    yield
  ensure
    configuration.instance_variable_set(:@base_url, previous)
    EndPointBlank::Commands::AuthenticationCache.instance.clear
  end

  private

  def accept_loop
    loop { handle(@server.accept) }
  rescue IOError, Errno::EBADF, Errno::EINVAL
    nil
  end

  def handle(socket)
    request_line = socket.gets
    return if request_line.nil?

    path = request_line.split(" ")[1].to_s
    headers = read_headers(socket)
    length = headers["content-length"].to_i
    body = length.positive? ? socket.read(length).to_s : ""

    @mutex.synchronize { @calls << Call.new(path: path, headers: headers, body: body) }
    socket.write(response_bytes)
  rescue Errno::EPIPE, Errno::ECONNRESET, IOError
    nil
  ensure
    begin
      socket&.close
    rescue IOError
      nil
    end
  end

  def read_headers(socket)
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, _, value = line.chomp.partition(":")
      headers[name.downcase] = value.strip
    end
    headers
  end

  def response_bytes
    [
      "HTTP/1.1 #{@status} #{REASONS.fetch(@status, 'Status')}",
      "Content-Type: #{@content_type}",
      "Content-Length: #{@body.bytesize}",
      "Connection: close",
      "",
      ""
    ].join("\r\n") + @body
  end
end
