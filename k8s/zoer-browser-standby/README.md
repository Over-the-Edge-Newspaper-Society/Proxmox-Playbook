# OTE Playwright startup

OTE starts Playwright only on demand. In Zoer’s Browsers settings, leave “Keep one clean on-demand browser ready” off. The saved workspace preference applies after restarts. The weekday prestart CronJobs were removed.

Verify that Browsers reports prestart disabled and zero standby sessions. An active, user-requested Playwright session can still use the worker.
