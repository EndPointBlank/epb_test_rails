#!/usr/bin/env bash
set -o errexit

cd "$(dirname "$0")"

# Local dev only: create the database if it doesn't exist. On Render the
# database is provisioned externally and reached via DATABASE_URL, so skip.
# `|| true` swallows the "already exists" failure on repeat runs.
if [ -z "$DATABASE_URL" ]; then
    PGPASSWORD="${PGPASSWORD:-postgres}" createdb \
        -h "${PGHOST:-localhost}" \
        -U "${PGUSER:-postgres}" \
        epb_test_rails_development 2>/dev/null || true
fi

bundle binstubs bundler --force
bundle install

# Bundler caches the git-pinned end_point_blank gem by SHA; force a refresh so
# updates pushed to master are picked up.
bundle update end_point_blank

bundle exec rake db:migrate
