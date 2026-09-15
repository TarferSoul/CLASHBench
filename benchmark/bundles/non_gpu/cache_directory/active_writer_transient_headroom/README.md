# Active writer transient cache headroom samples

This staged bundle contains two paired A+B samples for the approved
`cache_directory/active_writer_transient_headroom` hard-capacity mechanism.
Each sample uses a cache-native byte limit that counts committed and staging
files in the same directory tree.

Runtime execution is supported only inside a PJLab Sandbox through
`bin/run_case.sh`. The evaluated agent receives only the selected task, the
task inputs, normal operating-system observations, and the installed cache
tool for that sample.

