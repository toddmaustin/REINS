# Repository conventions

- Use `.cc` for first-party C++ source files and `.h` for first-party C++ headers.
- Keep includes, build targets, and documentation consistent with those names.
- Give every new or modified first-party function a short comment or docstring
  describing its purpose and each parameter. Keep interface and implementation
  comments consistent. Apply this to test helpers as well as production code.
- Preserve upstream and generated filenames in third-party dependencies and build
  outputs; the extension convention applies to code maintained in this repository.
- Add the Todd Austin copyright notice and
  `SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0` to new first-party source
  files owned by Todd Austin, following the existing header style and using the
  applicable year.
- Preserve upstream notices. Do not alter generated files, pinned specifications,
  or fixture bytes just to add headers; use the repository NOTICE or accompanying
  notices, while preserving the original licensing terms and provenance.
- Use the Makefile as the build/test interface; do not add CMake or Ninja setup.
- Run tests through the Make targets and preserve each run's logs/reports on disk.
  Delete retained results only through an explicit clean target.
