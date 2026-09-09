# frozen_string_literal: true

require "excon"

module Mesh
  # The one place this application speaks HTTP to the next application in the
  # ring.
  class Downstream
    # The base URL names the application; the path is ours to append. Both
    # inbound endpoints relay onto /mesh/relay -- /mesh/reports is the
    # negative control, and what it exists to prove is a refusal at the entry
    # point, not a second flavour of chain.
    RELAY_PATH = "/mesh/relay"

    CONNECT_TIMEOUT = 3
    READ_TIMEOUT = 10

    # Downstream errors are echoed back to the caller, so they are capped.
    MAX_ERROR_LENGTH = 500

    # status:: the downstream HTTP status, or nil when the call never got one
    #          (connection error, timeout).
    # body::   the downstream response body, parsed, on success.
    # error::  why the call is not usable, on failure.
    Response = Struct.new(:status, :body, :error, keyword_init: true) do
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
    # @param hops [Integer] the already-decremented budget to forward
    # @param run [String, nil] forwarded verbatim; omitted entirely when nil
    # @param payload [String, nil] opaque, forwarded
    # @return [Response]
    def post(base_url:, hops:, run:, payload:)
      url = relay_url(base_url)

      response = Excon.post(
        url,
        headers: request_headers(url, hops, run),
        body: request_body(payload),
        connect_timeout: CONNECT_TIMEOUT,
        read_timeout: READ_TIMEOUT
      )

      interpret(response)
    rescue Excon::Error => e
      # Excon::Error::Timeout covers both timeouts and Excon::Error::Socket
      # covers connection failures; both are Excon::Error.
      Response.new(status: nil, body: nil, error: truncate("#{e.class}: #{e.message}"))
    end

    private

    def relay_url(base_url)
      "#{base_url.to_s.sub(%r{/+\z}, "")}#{RELAY_PATH}"
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

    def interpret(response)
      status = response.status
      raw = response.body.to_s

      return Response.new(status: status, body: nil, error: truncate(raw)) unless status == 200

      Response.new(status: status, body: JSON.parse(raw), error: nil)
    rescue JSON::ParserError => e
      # A 200 carrying something that is not JSON is not a chain link; it is
      # more likely a proxy's error page. Reporting it as a failure keeps it
      # from nesting as a silently empty success.
      Response.new(
        status: status,
        body: nil,
        error: truncate("downstream answered #{status} but the body was not JSON: #{e.message}")
      )
    end

    def truncate(value)
      value.to_s[0, MAX_ERROR_LENGTH]
    end
  end
end
