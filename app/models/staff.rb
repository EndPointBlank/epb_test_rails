# frozen_string_literal: true

class Staff < ApplicationRecord
  self.table_name = "staffs"

  validates :first_name, :last_name, presence: true
end
