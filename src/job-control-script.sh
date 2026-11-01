# shellcheck shell=bash
set -m
"$@"
status=$?
resume_job() {
  kill -STOP $$
  fg >/dev/null
  status=$?
  if jobs %% >/dev/null 2>&1; then
    resume_job
  fi
}
if jobs %% >/dev/null 2>&1; then
  resume_job
fi
exit "$status"
