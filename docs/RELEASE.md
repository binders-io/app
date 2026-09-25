# Releasing Binders

A Mac opens a downloaded app without warnings only when it is signed with a **Developer ID** certificate, built with
the **hardened runtime**, and **notarized** by Apple. `scripts/release.sh` does all of it and leaves
`dist/Binders-<version>.dmg` and `.zip` ready to publish.

## Every release

1. Bump `MARKETING_VERSION` (what people see) and `CURRENT_PROJECT_VERSION` (must increase) in `project.yml`.
2. Write `docs/release-notes/<version>.md`.
3. Run `scripts/release.sh`. It runs the tests, archives a Release build, signs it for Developer ID, sends it to
   Apple's notary service, waits for approval (a few minutes), checks the signature, the stapled ticket and
   Gatekeeper's verdict, packs the DMG, the zip and the tarball with their checksums, writes the signed update feed, and
   moves the site's download button, version line and checksum to the new version.
4. Publish the GitHub release with the four files; the script prints the command. Every download of the app comes
   from there, the site's button and the updater included, so GitHub's download counts are the whole picture.
5. Commit the site change and push, then run `scripts/deploy-site.sh`: the site, then the feed, once the release's
   archive is reachable. People download the DMG, drag Binders to Applications and launch it. macOS says once that
   Apple checked it for malicious software; then the app asks for Microphone and Accessibility as usual.

## Updates (Sparkle)

Installed copies update themselves through [Sparkle](https://sparkle-project.org). The app carries the feed address
(`https://binders.io/appcast.xml`) and an EdDSA **public** key in its Info.plist. The matching **private** key is in the login
keychain of the Mac that cuts releases, under the account `binders`. `scripts/release.sh` signs each archive with it and rewrites
`dist/updates/appcast.xml`, pointing each archive at the GitHub release for its version; the feed itself lives at binders.io.
`scripts/deploy-site.sh` publishes the feed only once the release's archive answers, so no installed copy is ever offered a
file that isn't there. The signature is on the file, so where it is fetched from changes nothing for the updater.

- **The private key must be backed up.** Without it you cannot ship updates that installed copies accept. The backup lives
  in AWS Systems Manager Parameter Store as an encrypted SecureString, which is free on the Standard tier
  (Secrets Manager does the same job for about 40 cents per secret per month). See "Backing up the update key" below.
- The updater only offers a build whose `CURRENT_PROJECT_VERSION` is higher than the installed one. The release script refuses a
  build number that is already in the feed.
- Release notes: put `docs/release-notes/<version>.md` in place before releasing and they are embedded in the feed.
- People are asked on their second launch whether Binders may check automatically. It then checks at most once a day and sends no
  system profile. Settings → Updates has the switches and a Check Now button; the menu bar menu has Check for Updates.
- Test a feed without installing anything: `Binders --selftest-update-check <appcast url>` prints `UPDATE_FOUND …` or `NO_UPDATE …`.

## Backing up the update key

The key is exported to a temporary file, stored encrypted in Parameter Store, and the file is deleted. It is never printed.

```sh
KEYTOOL=$(find build build-release build-dev -path "*Sparkle/bin/generate_keys" | head -1)
F="${TMPDIR:-/tmp/}binders-sparkle.key"; rm -f "$F"
"$KEYTOOL" --account binders -x "$F" \
  && aws ssm put-parameter --region us-east-1 --name /binders/sparkle-ed25519-private-key --type SecureString \
       --description "Sparkle EdDSA private key for Binders updates (keychain account: binders)" --value "file://$F"
rm -f "$F"
```

Check it is there, without revealing it:

```sh
aws ssm get-parameter --region us-east-1 --name /binders/sparkle-ed25519-private-key \
  --query "Parameter.[Name,Type,LastModifiedDate]" --output text
```

Restore it on another Mac (the last line must print the public key in `project.yml`, `SUPublicEDKey`):

```sh
KEYTOOL=$(find build build-release build-dev -path "*Sparkle/bin/generate_keys" | head -1)
F="${TMPDIR:-/tmp/}binders-sparkle.key"
aws ssm get-parameter --region us-east-1 --name /binders/sparkle-ed25519-private-key --with-decryption \
  --query Parameter.Value --output text > "$F" && "$KEYTOOL" --account binders -f "$F"
rm -f "$F"
"$KEYTOOL" --account binders -p
```

If you prefer Secrets Manager, replace the `aws ssm put-parameter …` line with
`aws secretsmanager create-secret --region us-east-1 --name binders/sparkle-ed25519-private-key --secret-string "file://$F"`
and read it back with `aws secretsmanager get-secret-value --secret-id binders/sparkle-ed25519-private-key --query SecretString --output text`.

Anyone with access to that parameter can sign updates that every installed copy of Binders will accept. Keep the AWS account
locked down: use MFA, and do not grant `ssm:GetParameter` on `/binders/*` to anything that does not cut releases.

## The two routes

**Xcode account (default).** Xcode's signed-in Apple ID signs with a *cloud-managed* Developer ID certificate and
uploads to the notary service, so nothing has to be in the keychain. Requirements: the team in `project.yml` is in the
paid Apple Developer Program, and that Apple ID is signed in under Xcode → Settings → Accounts. Only the Account Holder
or an Admin with "cloud-managed Developer ID" access can sign this way. The disk image itself is not signed on this
route (there is no local private key); the app inside is signed, notarized and stapled, which is what Gatekeeper checks.

**Local certificate.** Used automatically when the keychain holds a "Developer ID Application" certificate *and*
notarytool credentials are stored as `binders-notary`. This route also signs and notarizes the disk image.

- Certificate: Xcode → Settings → Accounts → (team) → Manage Certificates… → + → Developer ID Application. Export a
  .p12 backup; Apple never gives the private key again.
- Credentials: make an app-specific password at appleid.apple.com, then
  `xcrun notarytool store-credentials binders-notary --apple-id you@example.com --team-id <TEAM ID>`.

Force a route with `BINDERS_RELEASE_MODE=xcode` or `=local`.

## Notes

- The release build has a different signature from the development build that `scripts/install.sh` puts in
  `~/Applications`. macOS ties Microphone and Accessibility permission to the signature, so a Mac that switches from one
  to the other is asked for those permissions again.
- Every build runs with the hardened runtime. Binders needs only the microphone entitlement. Accessibility, Screen
  Recording and Notifications are user permissions, not entitlements.
- Speech models are downloaded on first launch, so the DMG stays small.

## Not covered yet

- Automatic updates (Sparkle is the usual choice; it needs its own signing key and an appcast on binders.io).
- A download page.
- Crash reports.
