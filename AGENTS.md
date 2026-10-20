# Repository conventions

- Use `.cc` for first-party C++ source files and `.h` for first-party C++ headers.
- Keep includes, build targets, and documentation consistent with those names.
- Preserve upstream and generated filenames in third-party dependencies and build
  outputs; the extension convention applies to code maintained in this repository.
- Use the Makefile as the build/test interface; do not add CMake or Ninja setup.
- Run tests through the Make targets and preserve each run's logs/reports on disk.
  Delete retained results only through an explicit clean target.
