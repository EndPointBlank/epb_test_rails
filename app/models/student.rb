# frozen_string_literal: true

class Student < ApplicationRecord
  validates :first_name, :last_name, presence: true
end
