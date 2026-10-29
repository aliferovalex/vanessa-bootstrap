# Project initializer

See [the initialization guide](../doc/EDT-INITIALIZATION.md).

The initializer exports a source infobase and its extensions into EDT projects
or Designer XML files (`-SourceFormat XML`). XML mode does not require EDT CLI.
It requires Windows PowerShell 5.1 or 7, Git, Git LFS and 1C Designer.
Use the root initialize.cmd to include the template files in a new project.
Direct Initialize-Project.ps1 invocation without TemplateDirectory creates sources
in the selected format. Both formats use src/cf and src/cfe/<extension>.
Tests use executable doubles and temporary Git repositories, not real infobases.
