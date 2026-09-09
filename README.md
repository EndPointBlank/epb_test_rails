# epb_test_rails

One of the five `epb_test_*` applications that exercise the EndPointBlank
client libraries end to end. This one is the Rails harness.

## Running the test suite

```sh
bin/rails db:test:prepare test
```

The suite runs in parallel: `test/test_helper.rb` calls
`parallelize(workers: :number_of_processors)`, so minitest forks a worker per
core once the suite has more than 50 tests in it. That is what CI runs, and it
is what runs locally.

### If the suite segfaults on macOS

It should not any more, but the failure is distinctive enough to be worth
recognising. Forked workers die in `connect_start` with
`[BUG] Segmentation fault`, the parent process then hangs waiting on workers
that are already gone, and `~/Library/Logs/DiagnosticReports` fills up with one
`ruby-*.ips` report per worker.

The cause is not the tests. Before libpq offers GSSAPI encryption it calls
`pg_GSS_have_cred_cache`, which walks the Kerberos credential cache; on macOS
that walk talks to the Kerberos daemon over XPC, and an XPC connection
inherited across `fork()` cannot be used in the child. Any connection opened
by a forked worker crashes. It reproduces on every arm64 build of `pg` we
tried -- 1.6.0 through 1.6.3, bundled libpq 17 and 18, and a source build
against Homebrew's libpq -- so pinning the gem does not help.

The fix is `gssencmode: disable` on the `test:` database in
`config/database.yml` (sc-271). Nothing here authenticates with Kerberos, and
the setting is unrelated to TLS -- `sslmode` is separate and untouched.

If you hit this anyway -- a different adapter, another gem that reaches XPC
after `fork()` -- the workaround is to stop minitest forking at all:

```sh
PARALLEL_WORKERS=1 bin/rails test
```

That is a diagnostic, not a fix: it makes the suite slower and it stops the
suite exercising the forked path that CI exercises. Prefer it only to confirm
that a failure is fork-related, then fix the fork.

## Database

Postgres, configured in `config/database.yml` from `PGHOST` / `PGUSER` /
`PGPASSWORD` (defaulting to `localhost` and `postgres` / `postgres`).
Production reads `DATABASE_URL` instead.
