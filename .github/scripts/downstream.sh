#!/bin/sh
# Runs a downstream gem's own test suite with ziperu standing in for rubyzip.
#
#   .github/scripts/downstream.sh <git url> <subdir or .> <test command...>
#
# Expects ziperu to be installed as a gem already. A stand-in gem named
# rubyzip (version 3.7.0, no files, depending on ziperu) is built and
# installed so the project's `gem "rubyzip"` dependency resolves while
# `require "zip"` loads ziperu's lib/zip.rb. The project's own rubyzip
# version bound is loosened so the stand-in satisfies it.
set -eu
url=$1; sub=$2; shift 2
name=$(basename "$url" .git)
work=${DOWNSTREAM_WORK:-/tmp/downstream}
mkdir -p "$work"

shim="$work/rubyzip-shim"
if ! gem list -i rubyzip -v 3.7.0 >/dev/null 2>&1; then
  mkdir -p "$shim/lib"
  cat > "$shim/rubyzip.gemspec" <<'EOF'
Gem::Specification.new do |s|
  s.name = "rubyzip"
  s.version = "3.7.0"
  s.summary = "rubyzip stand-in backed by ziperu (downstream test harness)"
  s.authors = ["ziperu"]
  s.files = []
  s.require_paths = ["lib"]
  s.add_dependency "ziperu"
end
EOF
  (cd "$shim" && gem build rubyzip.gemspec -q && gem install --local --no-document rubyzip-3.7.0.gem)
fi

rm -rf "$work/$name"
git clone -q --depth 1 "$url" "$work/$name"
cd "$work/$name/$sub"
sed -i "/rubyzip/d" Gemfile
printf '\n# ziperu downstream harness: rubyzip is a stand-in that depends on ziperu\ngem "rubyzip", "3.7.0"\n' >> Gemfile
for f in *.gemspec; do
  [ -f "$f" ] && sed -i -E "s/(add_(runtime_)?dependency[( ]*['\"]rubyzip['\"]).*/\1/" "$f"
done
bundle install --quiet 2>&1 | tail -3
echo "--- rubyzip resolves to: $(bundle exec ruby -e 'require "zip"; puts "#{Zip.name} #{Ziperu::VERSION}"')"
echo "--- $name: $*"
"$@"
