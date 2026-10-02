"""Valid routing-only registry shared by the external entrypoint fixtures."""


def write_registry(engine):
    # fm_project_get requires github, base and required_check. Omit repo for
    # an external clone; fm_storage_init derives its roots from FM_HOME.
    # Private commands and confirmed policy belong in CONVENTIONS.md, not here.
    (engine / 'config.yaml').write_text('''vendor: mock
concurrency: 3
projects:
  app:
    github: owner/app
    base: trunk
    required_check: ci
''')
