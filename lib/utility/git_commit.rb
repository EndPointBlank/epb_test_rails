# frozen_string_literal: true

module Utility
  class GitCommit
    def self.commit_sha
      if Rails.root.join('.git').exist?
        `git rev-parse HEAD`.chomp
      elsif ENV['GIT_COMMIT']
        ENV['GIT_COMMIT']
      else
        '0'
      end
    end
  end
end
