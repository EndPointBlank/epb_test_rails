# frozen_string_literal: true

require "excon"

module Mesh
  # The one place this application speaks HTTP to the next application in the
  # ring.
  class Downstream
    CONNECT_TIMEOUT = 3
    READ_TIMEOUT = 10

    # Downstream errors are echoed back to the caller, so they are capped.
    MAX_ERROR_LENGTH = 500

    # status:: the downstream HTTP status, or nil when the call never got one
    #          (connection error, timeout).
    # body::   the downstream response body, parsed, on success.
    # error::  why the call is not usable, on failure.
    # origin:: the origin object the downstream failure already carried, if it
    #          had one -- i.e. the failure was observed deeper than here and
    #          has already been attributed. nil means this hop is the observer.
    #          See Mesh::Origin.
    Response = Struct.new(:status, :body, :error, :origin, keyword_init: true) do
      def ok?
        status == 200 && error.nil?
      end
    end

    # The authorization seam.
    #
    # The downstream call goes through the application's own EndPointBlank
    # client path so that cross-organization authorization is genuinely
    # exercised rather than bypassed by a raw HTTP client -- that is the
    # entire reason the mesh exists.
    #
    # sc-263 is still settling which credential and grant shape each call
    # presents (it is being rewritten from a two-organization layout to the
    # five-organization ring). Injecting the collaborator keeps that change a
    # one-line change here rather than a scattered one.
    #
    # @param authorization [#header] anything answering header(url) with an
    #   Authorization header value.
    attr_reader :authorization

    def initialize(authorization: EndPointBlank::Authorization)
      @authorization = authorization
    end

    # Make exactly one downstream call.
    #
    # Never raises for a downstream problem: a refusal, a timeout or a
    # non-200 comes back as a Response that is not ok?, so the caller can turn
    # it into a 502 that preserves the status. Swallowing a refusal into a 200
    # would hide the negative control that sc-263 provisions and sc-265
    # counts.
    #
    # @param base_url [String] the next application's base URL
    # @param path [String] the mesh path to call, which is the path the
    #   request being relayed arrived on. The base URL names the application;
    #   this names the endpoint, and it is the caller's to choose precisely so
    #   that /mesh/reports keeps relaying onto /mesh/reports.
    # @param hops [Integer] the already-decremented budget to forward
    # @param run [String, nil] forwarded verbatim; omitted entirely when nil
    # @param payload [String, nil] opaque, forwarded
    # @return [Response]
    def post(base_url:, path:, hops:, run:, payload:)
      url = peer_url(base_url, path)

      response = Excon.post(
        url,
        headers: request_headers(url, hops, run),
        body: request_body(payload),
        connect_timeout: CONNECT_TIMEOUT,
        read_timeout: READ_TIMEOUT
      )

      self.class.interpret(response.status, response.body)
    rescue Excon::Error => e
      # Excon::Error::Timeout covers both timeouts and Excon::Error::Socket
      # covers connection failures; both are Excon::Error.
      self.class.transport_failure("#{e.class}: #{e.message}")
    end

    # Map a downstream (status, raw body) pair onto a Response.
    #
    # Public, and on the class rather than the instance, because the ring rig
    # in the relay tests answers through EXACTLY this. `origin` only survives
    # depth because it is read out of the PARSED body before that body is
    # truncated into `error`; a test double that mapped its own answer some
    # other way would demonstrate the opposite of what it claims.
    #
    # @param status [Integer, nil]
    # @param raw [String, nil] the response body as it came off the wire
    # @return [Response]
    def self.interpret(status, raw)
      body = raw.to_s

      unless status == 200
        return Response.new(
          status: status,
          body: nil,
          error: truncate(body),
          origin: Origin.extract(parse_or_nil(body))
        )
      end

      Response.new(status: status, body: JSON.parse(body), error: nil, origin: nil)
    rescue JSON::ParserError => e
      # A 200 carrying something that is not JSON is not a chain link; it is
      # more likely a proxy's error page. Reporting it as a failure keeps it
      # from nesting as a silently empty success.
      Response.new(
        status: status,
        body: nil,
        error: truncate("downstream answered #{status} but the body was not JSON: #{e.message}"),
        origin: nil
      )
    end

    # A failure with no HTTP status at all: a connect error or a timeout.
    # There is no body, so there is no origin to recover and this hop is
    # necessarily the observer -- Mesh::Relay sets one, with a null status.
    #
    # @param message [String]
    # @return [Response]
    def self.transport_failure(message)
      Response.new(status: nil, body: nil, error: truncate(message), origin: nil)
    end

    def self.parse_or_nil(body)
      JSON.parse(body)
    rescue JSON::ParserError
      # A failure body that is not JSON simply carries no origin. It is not
      # itself an error: the downstream may be a proxy that never reached the
      # peer at all.
      nil
    end
    private_class_method :parse_or_nil

    def self.truncate(value)
      value.to_s[0, MAX_ERROR_LENGTH]
    end
    private_class_method :truncate

    private

    # A trailing slash on the base URL must not double the separator, and the
    # path keeps exactly one leading one, so the same peer answers whether the
    # deployment configured "https://host" or "https://host/".
    def peer_url(base_url, path)
      "#{base_url.to_s.sub(%r{/+\z}, "")}/#{path.to_s.sub(%r{\A/+}, "")}"
    end

    def request_headers(url, hops, run)
      headers = {
        "Content-Type" => "application/json",
        "Authorization" => @authorization.header(url),
        Mesh::HOPS_HEADER => hops.to_s
      }
      # Never generated. An absent run identifier stays absent.
      headers[Mesh::RUN_HEADER] = run unless run.nil?
      headers
    end

    def request_body(payload)
      payload.nil? ? "{}" : { payload: payload }.to_json
    end
  end
end
