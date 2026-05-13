#!/usr/bin/env bash
set -o errexit

cd "$(dirname "$0")"

bundle install
bundle exec rake db:migrate
