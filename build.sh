#!/usr/bin/env bash
set -o errexit

cd "$(dirname "$0")"

bundle binstubs bundler --force
bundle install
bundle exec rake db:migrate
