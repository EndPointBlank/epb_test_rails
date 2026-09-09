# frozen_string_literal: true

require "test_helper"

# The parse table from docs/superpowers/specs/2026-09-08-hop-budget-contract.md.
#
# Every case here is a case in that table. A missing or unparseable header is
# 0 -- STOP -- never "unlimited": that default is the whole safety property of
# a ring that would otherwise spin forever.
#
# Ruby makes this specific rule easy to get wrong, which is why it is tested
# value by value rather than by a single "it parses ints" assertion:
# "4abc".to_i is 4 and "abc".to_i is 0, both silently, so to_i would accept
# junk as a budget and never say so.
class Mesh::HopBudgetTest < ActiveSupport::TestCase
  # --- the zero cases -------------------------------------------------------

  test "an absent header is zero" do
    assert_equal 0, Mesh::HopBudget.parse(nil)
  end

  test "an empty header is zero" do
    assert_equal 0, Mesh::HopBudget.parse("")
  end

  test "a whitespace-only header is zero" do
    [ " ", "   ", "\t", "\t \t", "\r", "\f", "\v" ].each do |raw|
      assert_equal 0, Mesh::HopBudget.parse(raw), "expected #{raw.inspect} to parse to 0"
    end
  end

  test "a non-numeric header is zero" do
    [ "abc", "four", "n/a", "null", "undefined" ].each do |raw|
      assert_equal 0, Mesh::HopBudget.parse(raw), "expected #{raw.inspect} to parse to 0"
    end
  end

  test "a header that merely starts with digits is zero" do
    # The to_i trap: "4abc".to_i == 4. The contract says base-10 integer or
    # nothing, so a trailing tail makes the whole value invalid.
    [ "4abc", "4 hops", "4;q=1", "4.0.1" ].each do |raw|
      assert_equal 0, Mesh::HopBudget.parse(raw), "expected #{raw.inspect} to parse to 0"
    end
  end

  test "a non base-10 numeric header is zero" do
    [ "1.5", "0x4", "0b100", "1e3", "4_0" ].each do |raw|
      assert_equal 0, Mesh::HopBudget.parse(raw), "expected #{raw.inspect} to parse to 0"
    end
  end

  test "a signed header is zero" do
    # "+4" is explicitly in the table. Integer("+4") would accept it.
    [ "+4", "+0", "-1", "-100", "-0" ].each do |raw|
      assert_equal 0, Mesh::HopBudget.parse(raw), "expected #{raw.inspect} to parse to 0"
    end
  end

  test "zero is zero" do
    assert_equal 0, Mesh::HopBudget.parse("0")
    assert_equal 0, Mesh::HopBudget.parse("000")
  end

  test "a non-ASCII digit is zero" do
    assert_equal 0, Mesh::HopBudget.parse("٤")
  end

  # --- the accepting cases --------------------------------------------------

  test "a positive base-10 integer parses" do
    assert_equal 1, Mesh::HopBudget.parse("1")
    assert_equal 4, Mesh::HopBudget.parse("4")
    assert_equal 4, Mesh::HopBudget.parse("004")
    assert_equal 64, Mesh::HopBudget.parse("64")
  end

  test "leading and trailing ASCII whitespace is trimmed" do
    assert_equal 4, Mesh::HopBudget.parse(" 4 ")
    assert_equal 4, Mesh::HopBudget.parse("\t4\r\n")
  end

  test "the first value wins when the header repeats" do
    # Rack hands duplicate headers back joined -- with a comma by most
    # servers, with a newline under the Rack 3 spec. Either way the contract
    # says the FIRST value decides, so a second header cannot raise a budget.
    assert_equal 4, Mesh::HopBudget.parse("4,9")
    assert_equal 4, Mesh::HopBudget.parse("4, 9")
    assert_equal 4, Mesh::HopBudget.parse("4\n9")
    assert_equal 0, Mesh::HopBudget.parse("0,9")
    assert_equal 0, Mesh::HopBudget.parse(",9")
    assert_equal 0, Mesh::HopBudget.parse("junk,9")
  end

  test "the budget is clamped to 64 rather than rejected" do
    assert_equal 64, Mesh::HopBudget.parse("65")
    assert_equal 64, Mesh::HopBudget.parse("1000000")
    assert_equal 64, Mesh::HopBudget.parse("9" * 400)
  end

  test "the clamp is a constant, not a literal scattered around" do
    assert_equal 64, Mesh::HopBudget::MAX
  end
end
