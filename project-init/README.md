# Project initializer

See [the initialization guide](../doc/EDT-INITIALIZATION.md).

The initializer exports a source infobase and its extensions into EDT projects.
It requires Windows PowerShell 5.1 or 7, Git, Git LFS, 1C Designer and EDT CLI.
Use the root initialize.cmd to include the template files in a new project.
Direct Initialize-Project.ps1 invocation without TemplateDirectory creates only EDT sources.
Tests use executable doubles and temporary Git repositories, not real infobases.
