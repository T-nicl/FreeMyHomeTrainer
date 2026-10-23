#!/bin/zsh
# Fabrique (et publie) une version installable de FreeMyHomeTrainer, sans Xcode côté utilisateur.
#
#   scripts/release.sh 0.2.0        nouvelle version : numéro mis à jour, build, .zip, release GitHub
#   scripts/release.sh --build-only  build + .zip de la version actuelle, sans rien commiter ni publier
#
# L'app est signée avec le certificat « Apple Development » gratuit défini dans
# Config/Local.xcconfig. Sans compte développeur payant, elle n'est pas notarisée : au premier
# lancement, il faut cliquer sur « Ouvrir quand même » (Réglages Système › Confidentialité et
# sécurité). La signature restant la même d'une version à l'autre, les mises à jour ne
# redemandent rien et conservent la connexion Garmin.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { print -u2 "Erreur : $1"; exit 1; }

MODE=release
VERSION=${1:-}
if [[ "$VERSION" == "--build-only" ]]; then
    MODE=build
    VERSION=$(sed -nE 's/.*CFBundleShortVersionString: "([^"]+)".*/\1/p' project.yml)
elif [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    die "usage : scripts/release.sh X.Y.Z   ou   scripts/release.sh --build-only"
fi

[[ -f Config/Local.xcconfig ]] || die "Config/Local.xcconfig absent : sans lui, la signature changerait à chaque version."

if [[ $MODE == release ]]; then
    [[ "$(git branch --show-current)" == main ]] || die "à lancer depuis la branche main."
    [[ -z "$(git status --porcelain)" ]] || die "des modifications ne sont pas commitées."
    ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "la version $VERSION existe déjà."
    gh auth status >/dev/null 2>&1 || die "GitHub CLI non connecté (gh auth login)."

    print "→ Version $VERSION"
    BUILD=$(( $(sed -nE 's/.*CFBundleVersion: "([0-9]+)".*/\1/p' project.yml) + 1 ))
    sed -i '' -E "s/(CFBundleShortVersionString: )\"[^\"]*\"/\1\"$VERSION\"/; s/(CFBundleVersion: )\"[^\"]*\"/\1\"$BUILD\"/" project.yml
    xcodegen generate --quiet
    # Uniquement les fichiers de version : jamais un fichier de travail non voulu.
    git add project.yml FreeMyHomeTrainer.xcodeproj FreeMyHomeTrainer/Support/Info.plist
    git commit -q -m "Version $VERSION"
fi

print "→ Build Release (Apple Silicon + Intel)"
xcodebuild -project FreeMyHomeTrainer.xcodeproj -scheme FreeMyHomeTrainer -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/release -quiet build
APP=build/release/Build/Products/Release/FreeMyHomeTrainer.app

print "→ Vérifications"
codesign --verify --deep --strict "$APP" || die "signature invalide."
ARCHS=$(lipo -archs "$APP/Contents/MacOS/FreeMyHomeTrainer")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || die "architectures inattendues : $ARCHS"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$BUILT_VERSION" == "$VERSION" ]] || die "version compilée $BUILT_VERSION ≠ $VERSION"
SIGNER=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
print "   signée par : ${SIGNER:-ad hoc} · architectures : $ARCHS"

mkdir -p dist
ZIP="dist/FreeMyHomeTrainer-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"     # ditto conserve la signature
print "→ Archive : $ZIP"

[[ $MODE == release ]] || exit 0

print "→ Publication sur GitHub"
PREVIOUS=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)
NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT                 # nettoyé même en cas d'erreur
SHA256=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
{
    print "## Installer"
    print ""
    print "1. Télécharge **FreeMyHomeTrainer-$VERSION.zip** ci-dessous, puis double-clique dessus."
    print "2. Glisse **FreeMyHomeTrainer** dans le dossier **Applications**."
    print "3. Ouvre l'app : macOS refuse car elle n'est pas validée par Apple → clique sur **OK**."
    print "4. Ouvre **Réglages Système › Confidentialité et sécurité**, descends tout en bas et clique sur **Ouvrir quand même**, puis confirme avec le mot de passe du Mac."
    print "5. Autorise le Bluetooth quand l'app le demande."
    print ""
    print "**Mettre à jour** : remplace l'app dans Applications par la nouvelle version. Les séances, l'historique et la connexion Garmin sont conservés."
    print ""
    print "Nécessite macOS 15 ou plus récent (Mac Apple Silicon ou Intel)."
    print ""
    print "Empreinte SHA-256 du .zip (pour vérifier qu'il n'a pas été modifié : \`shasum -a 256 FreeMyHomeTrainer-$VERSION.zip\`) :"
    print ""
    print "\`$SHA256\`"
    print ""
    print "## Changements"
    print ""
    if [[ -n $PREVIOUS ]]; then
        git log --pretty='- %s' "$PREVIOUS..HEAD" | grep -v '^- Version ' || true
    else
        # Première version : la liste de tous les commits depuis le début serait illisible.
        print "Première version publique. Fonctionnalités et prise en main : voir le [README](https://github.com/T-nicl/FreeMyHomeTrainer#readme)."
        print ""
        print "🚧 La création de séances avec l'IA (Ollama) est en chantier : elle ne fonctionne bien que pour des demandes simples."
    fi
} > "$NOTES"

git tag -a "v$VERSION" -m "Version $VERSION"
git push -q --follow-tags
gh release create "v$VERSION" "$ZIP" --title "FreeMyHomeTrainer $VERSION" --notes-file "$NOTES"
print "✓ Version $VERSION publiée : $(gh release view "v$VERSION" --json url --jq .url)"
