require 'colored'
require 'json'
require 'tmpdir'
require 'uri'

LOCKFILE_MODES = %w[update fail warn].freeze
# Hosts of the public npm registry. npm rewrites registry.npmjs.org in package-lock.json to the configured registry
# by itself (replace-registry-host), Yarn 1 uses the URLs in yarn.lock as they are.
YARN_PUBLIC_REGISTRIES = %w[https://registry.yarnpkg.com/ https://registry.npmjs.org/].freeze
NPM_PUBLIC_REGISTRIES = %w[https://registry.yarnpkg.com/].freeze
# The first React Native version that reads ENTERPRISE_REPOSITORY for the artifacts its iOS pods download
# from Maven Central (Hermes, the prebuilt core and dependencies).
RN_ENTERPRISE_REPOSITORY = Gem::Version.new('0.81')

def get_env_variable(key)
  ENV[key].nil? || ENV[key] == '' ? nil : ENV[key]
end

def abort_with1(message)
  puts "@@[error] #{message}".red
  exit 1
end

def get_info_msg(message)
  puts " \n#{message.green}"
end

def get_warning_msg(message)
  puts "@@[warning] #{message}".yellow
end

def http_url(key)
  url = get_env_variable(key)
  return nil if url.nil?

  abort_with1("#{key} must be an http or https URL.") unless url.match?(%r{\Ahttps?://[^/\s]+/?\S*\z})
  abort_with1("#{key} must not contain a user or password.") if URI(url).userinfo
  url.end_with?('/') ? url : "#{url}/"
end

def project_files(repository_dir, name)
  Dir.glob(File.join(repository_dir, '**', name)).reject { |path| path.match?(%r{/(node_modules|Pods|build|\.git)/}) }
end

# Lockfiles that still point at the public registry: Yarn 1 yarn.lock (resolved URLs), and package-lock.json or
# npm-shrinkwrap.json with registry.yarnpkg.com URLs, which npm does not rewrite. Yarn 2+ and pnpm lockfiles hold
# no registry URLs. update: rewrite the URLs to the mirror in the cloned copy; fail: stop; warn: only warn.
def check_lockfiles(repository_dir, mirror, mode)
  checked = 0
  public_files = []
  updated = 0
  lockfiles = project_files(repository_dir, 'yarn.lock').map { |path| [path, YARN_PUBLIC_REGISTRIES] } +
              (project_files(repository_dir, 'package-lock.json') + project_files(repository_dir, 'npm-shrinkwrap.json')).map { |path| [path, NPM_PUBLIC_REGISTRIES] }
  lockfiles.each do |path, public_registries|
    content = File.read(path)
    relative = path.delete_prefix("#{repository_dir}/")
    if File.basename(path) == 'yarn.lock' && content.include?('__metadata:')
      puts "Lockfile: #{relative} is a Yarn 2+ lockfile (no registry URLs), no change"
      next
    end
    checked += 1
    count = public_registries.sum { |registry| content.scan(registry).size }
    if count.zero?
      if File.basename(path) != 'yarn.lock' && content.include?('https://registry.npmjs.org/')
        puts "Lockfile: #{relative} uses registry.npmjs.org, which npm redirects to the npm Mirror URL itself, no change"
      else
        puts "Lockfile: #{relative} has no URL on the public npm registry, no change"
      end
    elsif mode == 'update'
      public_registries.each { |registry| content = content.gsub(registry, mirror) }
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, content)
      File.rename(temp, path)
      updated += 1
      puts "Lockfile: #{relative} updated: #{count} URLs #{public_registries.join(', ')} -> #{mirror} (cloned copy only)"
    else
      puts "Lockfile: #{relative} has #{count} URLs on the public npm registry (#{public_registries.map { |r| URI(r).host }.join(', ')})"
      public_files << "#{relative} (#{count} URLs)"
    end
  end
  puts checked.zero? && lockfiles.empty? ? "Lockfile (mode: #{mode}): no npm or Yarn lockfile in the project" : "Lockfile (mode: #{mode}): #{checked} #{checked == 1 ? 'lockfile' : 'lockfiles'} checked: #{updated} updated, #{public_files.size} still on the public npm registry"
  return if public_files.empty?

  message = "#{public_files.join(', ')} downloads packages from the public npm registry. Point the lockfile at your artifact proxy in the project, or set the Lockfile input to update."
  mode == 'fail' ? abort_with1(message) : get_warning_msg(message)
end

SUDOERS_FILE = '/etc/sudoers.d/appcircle-npm-mirror'.freeze
SUDOERS_LINE = %(Defaults env_keep += "N_NODE_MIRROR"\n).freeze

# Install Node runs `sudo n <version>` on macOS, and sudo drops N_NODE_MIRROR. This keeps the variable through sudo.
# The file is the same on every run, holds no URL and no secret, and changes nothing for builds without
# N_NODE_MIRROR. It is checked with visudo before it is installed: a broken sudoers file would stop every later sudo.
def keep_node_mirror_through_sudo
  return puts('sudo: N_NODE_MIRROR is already kept') if File.exist?(SUDOERS_FILE) && File.read(SUDOERS_FILE) == SUDOERS_LINE

  temp = File.join(get_env_variable('AC_TEMP_DIR') || Dir.tmpdir, "appcircle-npm-mirror.#{Process.pid}")
  File.write(temp, SUDOERS_LINE)
  unless system('/usr/sbin/visudo', '-cqf', temp)
    File.delete(temp)
    abort_with1('The sudoers rule for N_NODE_MIRROR did not pass visudo; nothing was changed.')
  end
  installed = system('sudo', '-n', 'install', '-m', '0440', '-o', 'root', '-g', 'wheel', temp, SUDOERS_FILE)
  File.delete(temp)
  if installed
    puts "sudo: N_NODE_MIRROR is kept for Install Node (#{SUDOERS_FILE})"
  else
    get_warning_msg("Could not write #{SUDOERS_FILE} (no passwordless sudo). Install Node runs n with sudo, which drops N_NODE_MIRROR: select a Node.js version that the runner image already has.")
  end
end

# The React Native versions in the project's package.json files, from the declared dependency (for example
# "0.81.4" or "^0.81.0").
def react_native_versions(repository_dir)
  project_files(repository_dir, 'package.json').map do |path|
    spec = (JSON.parse(File.read(path))['dependencies'] || {})['react-native']
    version = spec && spec[/\d+\.\d+(\.\d+)?/]
    version && [path.delete_prefix("#{repository_dir}/"), Gem::Version.new(version)]
  rescue JSON::ParserError
    nil
  end.compact
end

npm = http_url('AC_MIRROR_NPM')
node = http_url('AC_MIRROR_NODE')
maven = http_url('AC_MIRROR_REACT_NATIVE_MAVEN')
if npm.nil? && node.nil? && maven.nil?
  puts 'AC_MIRROR_NPM, AC_MIRROR_NODE and AC_MIRROR_REACT_NATIVE_MAVEN are empty: the tools use their public hosts.'
  exit 0
end

lockfile_mode = (get_env_variable('AC_MIRROR_NPM_LOCKFILE') || 'update').downcase
abort_with1("AC_MIRROR_NPM_LOCKFILE must be one of #{LOCKFILE_MODES.join(', ')}.") unless LOCKFILE_MODES.include?(lockfile_mode)

env_file = get_env_variable('AC_ENV_FILE_PATH')
abort_with1('AC_ENV_FILE_PATH is not set.') if env_file.nil?

# Values for the later steps of this build only: nothing is written to ~/.npmrc or other files on the runner.
lines = []
if npm
  lines << "npm_config_registry=#{npm}"                     # npm, pnpm, and Yarn 1 for packages not in yarn.lock
  lines << "YARN_REGISTRY=#{npm}"                           # Yarn 1
  lines << "YARN_NPM_REGISTRY_SERVER=#{npm.chomp('/')}"     # Yarn 2+
  lines << "COREPACK_NPM_REGISTRY=#{npm.chomp('/')}"        # Corepack, which downloads Yarn 2+ and pnpm
end
# n (used by the Install Node step) reads N_NODE_MIRROR. Install Node runs n with sudo, which drops the
# environment unless the variable is preserved.
lines << "N_NODE_MIRROR=#{node.chomp('/')}" if node
# React Native 0.81 and later download Hermes and their prebuilt iOS frameworks from this Maven repository.
lines << "ENTERPRISE_REPOSITORY=#{maven.chomp('/')}" if maven
File.open(env_file, 'a') { |f| lines.each { |line| f.puts(line) } }

puts "npm Mirror: npm, pnpm, Yarn and Corepack -> #{npm || 'registry.npmjs.org (AC_MIRROR_NPM is empty)'}"
puts "npm Mirror: Node.js distributions -> #{node || 'nodejs.org (AC_MIRROR_NODE is empty)'}"
puts "npm Mirror: React Native Maven artifacts -> #{maven || 'repo1.maven.org (AC_MIRROR_REACT_NATIVE_MAVEN is empty)'}"
keep_node_mirror_through_sudo if node && RUBY_PLATFORM.include?('darwin')

repository_dir = get_env_variable('AC_REPOSITORY_DIR')
unless repository_dir && Dir.exist?(repository_dir) && !Dir.empty?(repository_dir)
  get_warning_msg('The repository is not cloned yet, so the lockfile and React Native checks are skipped. Place the npm Mirror step after Git Clone.')
  exit 0
end

check_lockfiles(repository_dir, npm, lockfile_mode) if npm

# Android build configurations set AC_MODULE and no AC_SCHEME (iOS ones the opposite); the Hermes and prebuilt
# framework downloads only happen in iOS builds. When in doubt, the step warns.
android_build = get_env_variable('AC_MODULE') && get_env_variable('AC_SCHEME').nil?
react_native_versions(repository_dir).each do |relative, version|
  next puts("React Native: #{relative} uses #{version} (Android build: the iOS Maven downloads do not apply)") if android_build

  if version < RN_ENTERPRISE_REPOSITORY
    get_warning_msg("#{relative}: React Native #{version} downloads Hermes for iOS from repo1.maven.org and has no setting to change it. React Native #{RN_ENTERPRISE_REPOSITORY} and later use AC_MIRROR_REACT_NATIVE_MAVEN.")
  elsif maven.nil?
    get_warning_msg("#{relative}: React Native #{version} downloads Hermes and prebuilt iOS frameworks from repo1.maven.org. Set AC_MIRROR_REACT_NATIVE_MAVEN to a Maven repository on your artifact proxy.")
  else
    puts "React Native: #{relative} uses #{version}, iOS artifacts from #{maven.chomp('/')}"
  end
end
get_info_msg('npm Mirror is configured.')
