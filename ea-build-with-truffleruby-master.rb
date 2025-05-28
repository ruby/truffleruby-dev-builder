require "fileutils"
require "json"

include FileUtils::Verbose

def sh(*args, **kwargs)
  puts "::group::$ #{args.join(" ")}"
  system(*args, exception: true, **kwargs)
  puts "::endgroup::"
end

os = case RbConfig::CONFIG['host_os']
in /linux/ then "linux"
in /darwin/ then "darwin"
end

arch = case RbConfig::CONFIG['host_cpu']
in /amd64|x86_64|x64/ then "amd64"
in /arm64|aarch64/ then "aarch64"
end

url = "https://github.com/graalvm/graal-languages-ea-builds/raw/HEAD/truffleruby/versions/latest-jvm-#{os}-#{arch}.url"
puts url
url = `curl -Ls #{url}`
puts url

ea_build_archive = "truffleruby-jvm-ea-build.tar.gz"

unless File.exist? ea_build_archive
  sh "wget", "--progress=dot:mega", "-O", ea_build_archive, url
end

ea_build = `tar tf truffleruby-jvm-ea-build.tar.gz | head -1`[/^(.+?)\//, 1]
puts "EA build dir: #{ea_build}"

unless Dir.exist? ea_build
  sh "tar", "xf", ea_build_archive
end

ea_files = Dir.glob("**/{*,.*}", base: ea_build)

ea_commit_info = File.read("#{ea_build}/release")[/COMMIT_INFO=(.+)/, 1]
ea_truffle_commit = JSON.load(ea_commit_info).fetch("truffle").fetch("commit.rev")
puts "EA build Truffle commit: #{ea_truffle_commit}"

# Build with the same truffle version as in ea_build
sh "git", "checkout", ea_truffle_commit, chdir: "../graal"
# unset JAVA_HOME to download the correct JDK from graal common.json
ENV.delete "JAVA_HOME"
sh({ "JT_IMPORTS_DONT_ASK" => "true" }, "bin/jt", "build")

master_build = "mxbuild/truffleruby-jvm"

master_files = Dir.glob("**/{*,.*}", base: master_build)

result = "truffleruby-jvm-ea-master-build"

EXPECTED_DIFFERENT = %w[
  jvm
]

OVERRIDE_WITH_EA_BUILD = %w[
  jvm
  release
]

EXPECTED_EXTRA_IN_EA_BUILD = %w[
  license-information-user-manual.zip
  DISCLAIMER.txt

  modules/nativebridge.jar
  modules/sulong-enterprise-native.jar
  modules/sulong-enterprise.jar
  modules/truffle-enterprise.jar
]

EXPECTED_EXTRA_IN_MASTER_BUILD = %w[
  3rd_party_licenses.txt
]

# There might be more or less files in these directories, that's OK, these are "Ruby home" files
CHANGES_ALLOWED_IN_MASTER_BUILD = %w[
  bin
  doc
  lib
  logo
  src
]

def check_diff(a_files, b_files, expected_extra)
  diff = a_files - b_files
  diff = diff.reject { |path| expected_extra.any? { |e| path.start_with?(e) } }
  unless diff.empty?
    puts diff
    raise "ERROR: Unexpected files!"
  end
end

puts "extra master files (master_files - ea_files)"
check_diff(master_files, ea_files, EXPECTED_EXTRA_IN_MASTER_BUILD + CHANGES_ALLOWED_IN_MASTER_BUILD + EXPECTED_DIFFERENT)

puts "extra EA files (ea_files - master_files)"
check_diff(ea_files, master_files, EXPECTED_EXTRA_IN_EA_BUILD + EXPECTED_DIFFERENT)

rm_rf result
cp_r master_build, result

EXPECTED_EXTRA_IN_MASTER_BUILD.each { |path|
  rm_r "#{result}/#{path}" if File.exist? "#{result}/#{path}"
}

(EXPECTED_EXTRA_IN_EA_BUILD + OVERRIDE_WITH_EA_BUILD).each { |path|
  rm_r "#{result}/#{path}" if File.exist? "#{result}/#{path}"
  cp_r "#{ea_build}/#{path}", "#{result}/#{path}"
}

result_files = Dir.glob("**/{*,.*}", base: result)
puts "extra result files (result_files - ea_files)"
check_diff(result_files, ea_files, [])

# Run specs after to make sure it works correctly:
sh "bin/jt", "-u", "#{Dir.pwd}/#{result}", "test", "fast"
