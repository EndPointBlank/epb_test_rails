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

# Re-resolve the SDK through the Gemfile. Bundler caches a git dep by SHA, so
# without this a stale checkout can keep an old revision after the Gemfile
# changes.
#
# This no longer picks up "updates pushed to master", as it once did and as this
# comment used to claim: the Gemfile pins an exact tag, so this re-resolves to
# that same tag. That is the point -- this script runs on deploy, and a deploy
# taking whatever the SDK's master happened to be was never safe. Verified: with
# the tag pinned, this leaves Gemfile.lock unchanged.

bundle exec rake db:migrate
