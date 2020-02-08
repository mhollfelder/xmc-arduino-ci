# Folder structure

# Definitions of the URIs for the release
REPOSITORY_RELEASE_URL="https://github.com/mhollfelder/xmc-arduino-ci/releases/download"
REPOSITORY_NIGHTLY_URL="https://github.com/mhollfelder/xmc-arduino-ci-nightly/releases/download"
REPO_API_URL="https://api.github.com/repos/mhollfelder/xmc-arduino-ci/releases"
REPO_API_NIGHTLY_URL="https://api.github.com/repos/mhollfelder/xmc-arduino-ci-nightly/releases"

REPO_UPLOAD_URL="https://uploads.github.com/repos/mhollfelder/xmc-arduino-ci/releases"
REPO_UPLOAD_NIGHTLY_URL="https://uploads.github.com/repos/mhollfelder/xmc-arduino-ci-nightly/releases"
JSON_URI_REPO="https://github.com/mhollfelder/xmc-arduino-ci/releases/download"
JSON_URI_NIGHTLY_REPO="https://github.com/mhollfelder/xmc-arduino-ci/releases-nightly/download"

# State variables
is_nightly=0
plain_ver=-1
ver=-1

# Extract next version from platform.txt
next=`sed -n -E 's/version=([0-9.]+)/\1/p' ../platform.txt`

# Figure out how will the package be called
# Note on if [ $? -ne 0 ]; then
# Travis CI has problems with $?, see this issue https://github.com/travis-ci/travis-ci/issues/3771 for alternative
commit=`git rev-parse --short HEAD`
ver=`git describe --exact-match` 
if [ $? -ne 0 ]; then
    # Not tagged version
    # Generate nightly package
    date_str=`date +"%Y%m%d"`
    is_nightly=1
    plain_ver="${next}-nightly"
    # Commit only for testing
    ver="${plain_ver}+${date_str}+${commit}"
else
    plain_ver=$ver
fi
visiblever=$ver

# From help:
# Exit immediately if a simple command exits with a non-zero status, unless 
# the command that fails is part of an until or  while loop, part of an
# if statement, part of a && or || list, or if the command's return status
# is being inverted using !
set -e

# Set the package name accordingly
package_name=XMC_IFX_$visiblever

# Print information about the package
echo "Version: $visiblever ($ver)"
echo "Package name: $package_name"

# Set REMOTE_URL environment variable to the address where the package will be
# available for download. This gets written into package json file.
if [ -z "$REMOTE_URL" ]; then
    REMOTE_URL="$REPOSITORY_RELEASE_URL"
    echo "REMOTE_URL not defined, using default"
fi
echo "Remote: $REMOTE_URL"

## Fix this with GitHub asset process
if [ -z "$PKG_URL" ]; then
    if [ -z "$PKG_URL_PREFIX" ]; then
        PKG_URL_PREFIX="$REMOTE_URL/$visiblever"
    fi
    PKG_URL="$PKG_URL_PREFIX/$package_name.zip"
fi
echo "Package: $PKG_URL"

# Create directory for the package
srcdir=$PWD
rootdir=$srcdir/..
outdir=$rootdir/package/versions/$visiblever/$package_name
rm -rf $rootdir/package/versions/$visiblever
mkdir -p $outdir

# Some files should be excluded from the package
cat << EOF > exclude.txt
.git
.gitignore
.gitmodules
.travis.yml
package
doc
scripts
EOF
# Also include all files which are ignored by git
git ls-files --other --directory >> exclude.txt
# Now copy files to $outdir
rsync -a --exclude-from 'exclude.txt' $rootdir/ $outdir/
rm exclude.txt

# For compatibility, on OS X we need GNU sed which is usually called 'gsed'
if [ "$(uname)" == "Darwin" ]; then
    SED=gsed
else
    SED=sed
fi

# Zip the package
pushd $rootdir/package/versions/$visiblever
ls ./
echo "Making $package_name.zip"
ls ./
echo $package_name
#zip -qr $package_name.zip $package_name
zip -qr $package_name.zip ./
rm -rf $package_name

# Calculate SHA sum and size
sha=`shasum -a 256 $package_name.zip | cut -f 1 -d ' '`
size=`/bin/ls -l $package_name.zip | awk '{print $5}'`
echo Size: $size
echo SHA-256: $sha

# If nightly

echo "Creating a nightly release"
echo "Making package_infineon_nightly_index.json"

jq_arg=".packages[0].platforms[0].version = \"$visiblever\" | \
    .packages[0].platforms[0].url = \"$PKG_URL\" |\
    .packages[0].platforms[0].archiveFileName = \"$package_name.zip\""

if [ -z "$is_nightly" ]; then
    jq_arg="$jq_arg |\
        .packages[0].platforms[0].size = \"$size\" |\
        .packages[0].platforms[0].checksum = \"SHA-256:$sha\""
fi

cat $rootdir/scripts/package_infineon_index.template.json | \
    jq "$jq_arg" > package_infineon_nightly_index.json

curl_gh_token_arg=()
if [ ! -z "$CI_GITHUB_API_ENVIRONMENT" ]; then
    curl_gh_token_arg=(-H "Authorization: token $CI_GITHUB_API_ENVIRONMENT")
fi

# Get previous release name
curl --silent "${curl_gh_token_arg[@]}" "$REPO_API_NIGHTLY_URL" > releases.json
cat releases.json

# Previous final release (prerelase == false)
prev_release=$(jq -r '. | map(select(.draft == false and .prerelease == false)) | sort_by(.created_at | - fromdateiso8601) | .[0].tag_name' releases.json)
# Previous release (possibly a pre-release)
prev_any_release=$(jq -r '. | map(select(.draft == false)) | sort_by(.created_at | - fromdateiso8601)  | .[0].tag_name' releases.json)
# Previous pre-release
prev_pre_release=$(jq -r '. | map(select(.draft == false and .prerelease == true)) | sort_by(.created_at | - fromdateiso8601)  | .[0].tag_name' releases.json)

echo "Previous release: $prev_release"
echo "Previous (pre-?)release: $prev_any_release"
echo "Previous pre-release: $prev_pre_release"

if [ "$prev_any_release" == "$visiblever" ]; then
    echo "Release already done, nothing to do!"
    exit 1
fi

# Make all released versions available in one package
base_ver=$prev_any_release

# Download previous release
echo "Downloading base package: $base_ver"
old_json=package_infineon_nightly_index.json
curl -L -o $old_json "$JSON_URI_NIGHTLY_REPO/${base_ver}/package_infineon_nightly_index.json"
new_json=package_infineon_nightly_index.json

set +e
# Merge the old and new, then drop any obsolete package versions
python3 $rootdir/scripts/merge_packages.py $new_json $old_json >tmp && mv tmp $new_json && rm $old_json

# Verify the JSON file can be read, fail if it's not OK
set -e
cat $new_json | jq empty

# Get the release notes
# release_notes=$(cat "$srcdir/RELEASE.md")

# Create the release and push it to GitHub
generate_post_data()
{
  cat <<EOF
{
  "tag_name": "${visiblever}",
  "target_commitish": "master",
  "name": "Nightly release of version ${visiblever}",
  "body": "## This nightly release is based on Infineon/XMC-for-Arduino@${commit}\nClick [here]() to see the changes included with this release!",
  "draft": false,
  "prerelease": true
}
EOF
}

echo "${curl_gh_token_arg[@]}"
echo --data "$(generate_post_data)"


echo "Creating the new release"
curl --silent "${curl_gh_token_arg[@]}" --data "$(generate_post_data)" "$REPO_API_NIGHTLY_URL" > reply_release.json

echo "Output reply from release"
cat reply_release.json

asset_uri=$(jq -r '. | .upload_url' reply_release.json)

asset_uri=${asset_uri//\{?name,label\}/}

echo "Asset URI is $asset_uri"

echo "Uploading the package"
curl --silent "${curl_gh_token_arg[@]}" --data-binary "$package_name.zip" -H "Content-Type: application/octet-stream" "${asset_uri}?name=$package_name.zip"

popd

echo "All done for nightly build"
