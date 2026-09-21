# Contributing

Thanks for looking. Bug reports and pull requests are welcome.

## Before you open a pull request

- `cd Packages/BindersKit && swift test` must pass, and `scripts/coverage.sh` must stay above its threshold. CI runs both.
- Logic that can be tested without a microphone or a model belongs in `Packages/BindersKit`, with tests.
- Run `xcodegen generate` after adding a file; the Xcode project is generated and not committed.
- Never put real names, email addresses or recordings in code, tests or fixtures. Use invented ones.
- Found a security problem? Please write to security@binders.io before opening a public issue.

## Licence of contributions

Binders is licensed under the GNU General Public License, version 3 (`LICENSE`). By submitting a contribution you confirm that
you wrote it, or otherwise have the right to submit it, and you agree that:

1. your contribution is licensed to everyone under the GNU General Public License, version 3; and
2. you grant Helder Feixas, the publisher of Binders, a perpetual, worldwide, non-exclusive, royalty-free, irrevocable licence to
   use, modify, sublicense and relicense your contribution, including under other licence terms.

The second point is what lets the project change or add licences later without tracking down every contributor. You keep the
copyright in what you wrote.
