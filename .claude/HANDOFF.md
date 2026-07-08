# Session Handoff

**Branch**: nightly
**When**: 2026-07-05 23:27:56 UTC
**Session**: 0e003c07-8966-4727-bd67-48cc34778476

## Summary
It already works exactly that way — the module never copies anything into `/var/lib/jesse`. Here's what the generated unit does when `strategiesDir` is set (this is the actual rendered `preStart` from the eval I ran before pushing):

```bash
mkdir -p storage
ln -sfn /srv/jesse-strategies strategies   # /var/lib/jesse/strategies -> your dir
```

So `/var/lib/jesse/strategies` is just a symlink to whatever you pointed at, re-pointed on every service start.

## Modified Files
- .claude/HANDOFF.md
- .claude/hooks/logs/security/aggregated-report.json

## Patterns Noted
- It already works exactly that way — the module never copies anything into `/var/lib/jesse`.
