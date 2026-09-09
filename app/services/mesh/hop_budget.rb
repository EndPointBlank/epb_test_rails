# frozen_string_literal: true

module Mesh
  # Parses the X-EPB-Test-Hops header into a budget.
  #
  # `n` is 0 unless the header is a base-10 integer greater than zero. Absent,
  # empty, whitespace-only, non-numeric, signed, fractional, hexadecimal,
  # negative and zero all parse to 0, and 0 means STOP.
  #
  # A missing header must never mean "unlimited". That is the one default that
  # can run away, and it would run away inside a ring, on a box that is
  # simultaneously being measured.
  #
  # String#to_i is exactly the wrong tool for this: "4abc".to_i is 4 and
  # "abc".to_i is 0, both silently, so it would accept junk as a budget and
  # never say so. Integer() is closer but still accepts "+4", "0x4" and "4_0",
  # all of which the contract's table calls 0. Hence the explicit match.
  module HopBudget
    # A budget above the clamp is treated as the clamp rather than rejected:
    # that bounds a typo (X-EPB-Test-Hops: 1000000) without introducing a
    # failure mode the load driver has to handle. 64 is 12 full laps of a
    # five-node ring.
    MAX = 64

    # Deliberately [0-9] and not \d with a Unicode flag, and anchored at both
    # ends: base-10 digits, all of them, nothing else.
    BASE_10 = /\A[0-9]+\z/

    # ASCII whitespace only, per the contract. String#strip would also strip
    # NUL, which is not whitespace and has no business arriving in a header.
    LEADING_WHITESPACE = /\A[ \t\r\n\f\v]+/
    TRAILING_WHITESPACE = /[ \t\r\n\f\v]+\z/

    module_function

    # @param raw [String, nil] the raw header value as the server handed it over
    # @return [Integer] 0..MAX
    def parse(raw)
      value = trim(first_value(raw))
      return 0 unless BASE_10.match?(value)

      [ Integer(value, 10), MAX ].min
    end

    # If the header appears more than once, the FIRST value decides -- a
    # second header must never be able to raise a budget. Rack servers hand
    # duplicates back joined, with a comma by convention and with a newline
    # under the Rack 3 spec, so both separators are honoured.
    def first_value(raw)
      raw.to_s.split(/[,\n]/, 2).first.to_s
    end

    def trim(value)
      value.sub(LEADING_WHITESPACE, "").sub(TRAILING_WHITESPACE, "")
    end
  end
end
