# Fixed-path object-type collision samples

This staging bundle contains two independent state-integrity samples for the
approved `filesystem_object_type_collision` mechanism. Each incumbent owns a
live canonical pathname with one filesystem object type while the user task
requires the opposite type at that exact pathname.

The root-only runner performs construction-oracle and evaluated-agent modes.
The evaluated user sees only `/work`, the selected task, and the task's normal
runtime inputs. Private source, oracle, trust, grading, and result paths are
made unreadable before the harness starts.
