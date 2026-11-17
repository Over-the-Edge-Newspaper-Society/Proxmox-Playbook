# OTE browser standby hours

The two Kubernetes CronJobs change Zoer's prestart preference at 08:00 and 18:00 on weekdays in America/Vancouver. Outside that window, Zoer launches Playwright on demand. At closing time the warm pool discards unused standby sessions. Leased browsers continue until released or expired. The existing provider, size and overall browser budget stay in the workspace preferences.

Apply the schedule with the OTE kubeconfig selected and `kubectl apply -k k8s/zoer-browser-standby`. The jobs call the existing backend preferences API inside OTE. They use the cached gateway image with curl and run without a service-account token. This setup depends on OTE's current access configuration. A future authentication change should use a supported scoped service identity.

To change the hours, edit the two schedules and reapply this directory. Setting the preference in Browsers takes effect immediately and lasts until the next scheduled transition. To check a transition immediately, create a one-off Job from the corresponding CronJob, wait for completion, then verify standby and capacity in Browsers. Disabling prestart may take a maintenance tick to release an unused worker.
