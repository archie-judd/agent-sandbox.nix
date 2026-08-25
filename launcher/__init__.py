# Deliberately empty. Importing launcher.lib.constants imports this first, and
# apply_network_rules runs on the Linux hot path, inside pasta's namespace,
# before anything is sandboxed. Anything added here is imported there too.
