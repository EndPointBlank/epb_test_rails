#!/usr/bin/env bash
set -o errexit

cd "$(dirname "$0")"

rails db:setup

bundle install
bundle exec rake db:migrate
