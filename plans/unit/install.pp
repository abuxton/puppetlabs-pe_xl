# @summary Perform initial installation of Puppet Enterprise Extra Large
#
# @param r10k_remote
#   The clone URL of the controlrepo to use. This just uses the basic config
#   from the documentaion https://puppet.com/docs/pe/2019.0/code_mgr_config.html
#
# @param r10k_private_key
#   The private key to use for r10k. If this is a local file it will be copied
#   over to the masters at /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa
#   If the file does not exist the value will simply be supplied to the masters
#
# @param pe_conf_data
#   Config data to plane into pe.conf when generated on all hosts, this can be
#   used for tuning data etc.
#
plan pe_xl::unit::install (
  # Large
  String[1]           $master_host,
  Array[String[1]]    $compiler_hosts      = [ ],
  Optional[String[1]] $master_replica_host = undef,

  # Extra Large
  Optional[String[1]] $puppetdb_database_host         = undef,
  Optional[String[1]] $puppetdb_database_replica_host = undef,

  # Common Configuration
  String[1]           $console_password,
  String[1]           $version       = '2019.1.1',
  Array[String[1]]    $dns_alt_names = [ ],
  Hash                $pe_conf_data  = { },

  # Code Manager
  Optional[String]     $r10k_remote              = undef,
  Optional[String]     $r10k_private_key_file    = undef,
  Optional[Pe_xl::Pem] $r10k_private_key_content = undef,

  # Other
  String[1]           $stagingdir   = '/tmp',
) {

  # Define a number of host groupings for use later in the plan
  $core_hosts = [
    $master_host,
    $puppetdb_database_host,
  ].pe_xl::flatten_compact()

  $ha_hosts = [
    $master_replica_host,
    $puppetdb_database_replica_host,
  ].pe_xl::flatten_compact()

  $ha_replica_target = [
    $master_replica_host,
  ].pe_xl::flatten_compact()

  $puppetdb_database_target = [
    $puppetdb_database_host,
  ].pe_xl::flatten_compact()

  $puppetdb_database_replica_target = [
    $puppetdb_database_replica_host,
  ].pe_xl::flatten_compact()

  # Ensure valid input for HA
  $ha = $ha_hosts.size ? {
    0       => false,
    2       => true,
    default => fail('Must specify either both or neither of master_replica_host, puppetdb_database_replica_host'),
  }

  # Ensure primary external database host for HA
  if $ha {
    if ! $puppetdb_database_host {
      fail('Must specify puppetdb_database_host for HA environment')
    }
  }

  $all_hosts = [
    $core_hosts,
    $ha_hosts,
    $compiler_hosts,
  ].pe_xl::flatten_compact()

  $database_hosts = [
    $puppetdb_database_host,
    $puppetdb_database_replica_host,
  ].pe_xl::flatten_compact()

  $pe_installer_hosts = [
    $master_host,
    $puppetdb_database_host,
    $puppetdb_database_replica_host,
  ].pe_xl::flatten_compact()

  $agent_installer_hosts = [
    $compiler_hosts,
    $master_replica_host,
  ].pe_xl::flatten_compact()

  # There is currently a problem with OID names in csr_attributes.yaml for some
  # installs. Use the raw OIDs for now.
  $pp_application = '1.3.6.1.4.1.34380.1.1.8'
  $pp_cluster     = '1.3.6.1.4.1.34380.1.1.16'
  $pp_role        = '1.3.6.1.4.1.34380.1.1.13'

  # Clusters A and B are used to divide PuppetDB availability for compilers
  if $ha {
    $cm_cluster_a = $compiler_hosts.filter |$index,$cm| { $index % 2 == 0 }
    $cm_cluster_b = $compiler_hosts.filter |$index,$cm| { $index % 2 != 0 }
  }
  else {
    $cm_cluster_a = $compiler_hosts
    $cm_cluster_b = []
  }

  $dns_alt_names_csv = $dns_alt_names.reduce |$csv,$x| { "${csv},${x}" }

  # Process user input for r10k private key (content or file) and set
  # appropriate value in $r10k_private_key. The value of this variable should
  # either be undef or else the key content to write.
  $r10k_private_key = [
    $r10k_private_key_file,
    $r10k_private_key_content,
  ].pe_xl::flatten_compact.size ? {
    0 => undef, # no key data supplied
    2 => fail('Must specify either one or neither of r10k_private_key_file and r10k_private_key_content; not both'),
    1 => $r10k_private_key_file ? {
      String => file($r10k_private_key_file), # key file path supplied, read data from file
      undef  => $r10k_private_key_content,    # key content supplied directly, use as-is
    },
  }

  # Validate that the name given for each system is both a resolvable name AND
  # the configured hostname.
  run_task('pe_xl::hostname', $all_hosts).each |$result| {
    if $result.target.name != $result['hostname'] {
      fail_plan("Hostname / DNS name mismatch: target ${result.target.name} reports '${result['hostname']}'")
    }
  }

  # Generate all the needed pe.conf files
  $master_pe_conf = pe_xl::generate_pe_conf({
    'console_admin_password'                                          => $console_password,
    'puppet_enterprise::puppet_master_host'                           => $master_host,
    'pe_install::puppet_master_dnsaltnames'                           => $dns_alt_names,
    'puppet_enterprise::profile::puppetdb::database_host'             => $puppetdb_database_host,
    'puppet_enterprise::profile::master::code_manager_auto_configure' => true,
    'puppet_enterprise::profile::master::r10k_private_key'            => '/etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa',
    'puppet_enterprise::profile::master::r10k_remote'                 => $r10k_remote,
  } + $pe_conf_data)

  $puppetdb_database_pe_conf = pe_xl::generate_pe_conf({
    'console_admin_password'                => 'not used',
    'puppet_enterprise::puppet_master_host' => $master_host,
    'puppet_enterprise::database_host'      => $puppetdb_database_host,
  } + $pe_conf_data)

  $puppetdb_database_replica_pe_conf = pe_xl::generate_pe_conf({
    'console_admin_password'                => 'not used',
    'puppet_enterprise::puppet_master_host' => $master_host,
    'puppet_enterprise::database_host'      => $puppetdb_database_replica_host,
  } + $pe_conf_data)

  # Upload the pe.conf files to the hosts that need them
  pe_xl::file_content_upload($master_pe_conf, '/tmp/pe.conf', $master_host)
  pe_xl::file_content_upload($puppetdb_database_pe_conf, '/tmp/pe.conf', $puppetdb_database_target)
  pe_xl::file_content_upload($puppetdb_database_replica_pe_conf, '/tmp/pe.conf', $puppetdb_database_replica_target)

  # Download the PE tarball and send it to the nodes that need it
  $pe_tarball_name     = "puppet-enterprise-${version}-el-7-x86_64.tar.gz"
  $local_tarball_path  = "${stagingdir}/${pe_tarball_name}"
  $upload_tarball_path = "/tmp/${pe_tarball_name}"

  run_plan('pe_xl::util::retrieve_and_upload',
    nodes       => $pe_installer_hosts,
    source      => "https://s3.amazonaws.com/pe-builds/released/${version}/puppet-enterprise-${version}-el-7-x86_64.tar.gz",
    local_path  => $local_tarball_path,
    upload_path => $upload_tarball_path,
  )

  # Create csr_attributes.yaml files for the nodes that need them
  run_task('pe_xl::mkdir_p_file', $master_host,
    path    => '/etc/puppetlabs/puppet/csr_attributes.yaml',
    content => @("HEREDOC"),
      ---
      extension_requests:
        ${pp_application}: "puppet"
        ${pp_role}: "pe_xl::master"
        ${pp_cluster}: "A"
      | HEREDOC
  )

  run_task('pe_xl::mkdir_p_file', $puppetdb_database_target,
    path    => '/etc/puppetlabs/puppet/csr_attributes.yaml',
    content => @("HEREDOC"),
      ---
      extension_requests:
        ${pp_application}: "puppet"
        ${pp_role}: "pe_xl::puppetdb_database"
        ${pp_cluster}: "A"
      | HEREDOC
  )

  run_task('pe_xl::mkdir_p_file', $puppetdb_database_replica_target,
    path    => '/etc/puppetlabs/puppet/csr_attributes.yaml',
    content => @("HEREDOC"),
      ---
      extension_requests:
        ${pp_application}: "puppet"
        ${pp_role}: "pe_xl::puppetdb_database"
        ${pp_cluster}: "B"
      | HEREDOC
  )

  # Get the master installation up and running. The installer will
  # "fail" because PuppetDB can't start, if puppetdb_database_host
  # is set. That's expected.
  $shortcircuit_puppetdb = $puppetdb_database_host ? {
    undef   => false,
    default => true,
  }
  without_default_logging() || {
    out::message("Starting: task pe_xl::pe_install on ${master_host}")
    run_task('pe_xl::pe_install', $master_host,
      _catch_errors         => $shortcircuit_puppetdb,
      tarball               => $upload_tarball_path,
      peconf                => '/tmp/pe.conf',
      shortcircuit_puppetdb => $shortcircuit_puppetdb,
    )
    out::message("Finished: task pe_xl::pe_install on ${master_host}")
  }

  if $r10k_private_key {
    run_task('pe_xl::mkdir_p_file', [$master_host, $ha_replica_target],
      path    => '/etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa',
      owner   => 'pe-puppet',
      group   => 'pe-puppet',
      mode    => '0400',
      content => $r10k_private_key,
    )
  }

  # Configure autosigning for the puppetdb database hosts 'cause they need it
  $autosign_conf = $database_hosts.reduce |$memo,$host| { "${host}\n${memo}" }
  run_task('pe_xl::mkdir_p_file', $master_host,
    path    => '/etc/puppetlabs/puppet/autosign.conf',
    owner   => 'pe-puppet',
    group   => 'pe-puppet',
    mode    => '0644',
    content => $autosign_conf,
  )

  # Run the PE installer on the puppetdb database hosts
  run_task('pe_xl::pe_install', $database_hosts,
    tarball => $upload_tarball_path,
    peconf  => '/tmp/pe.conf',
  )

  # Now that the main PuppetDB database node is ready, finish priming the
  # master. Explicitly stop puppetdb first to avoid any systemd interference.
  run_command('systemctl stop pe-puppetdb', $master_host)
  run_command('systemctl start pe-puppetdb', $master_host)
  run_task('pe_xl::rbac_token', $master_host,
    password => $console_password,
  )

  # Stub a production environment and commit it to file-sync. At least one
  # commit (content irrelevant) is necessary to be able to configure
  # replication. A production environment must exist when committed to avoid
  # corrupting the PE console. Create the site.pp file specifically to avoid
  # breaking the `puppet infra configure` command.
  run_task('pe_xl::mkdir_p_file', $master_host,
    path    => '/etc/puppetlabs/code-staging/environments/production/manifests/site.pp',
    chown_r => '/etc/puppetlabs/code-staging/environments',
    owner   => 'pe-puppet',
    group   => 'pe-puppet',
    mode    => '0644',
    content => "# Empty manifest\n",
  )

  run_task('pe_xl::code_manager', $master_host,
    action => 'file-sync commit',
  )

  # Deploy the PE agent to all remaining hosts
  run_task('pe_xl::agent_install', $ha_replica_target,
    server        => $master_host,
    install_flags => [
      '--puppet-service-ensure', 'stopped',
      "main:dns_alt_names=${dns_alt_names_csv}",
      'extension_requests:pp_application=puppet',
      'extension_requests:pp_role=pe_xl::master',
      'extension_requests:pp_cluster=B',
    ],
  )

  run_task('pe_xl::agent_install', $cm_cluster_a,
    server        => $master_host,
    install_flags => [
      '--puppet-service-ensure', 'stopped',
      "main:dns_alt_names=${dns_alt_names_csv}",
      'extension_requests:pp_application=puppet',
      'extension_requests:pp_role=pe_xl::compiler',
      'extension_requests:pp_cluster=A',
    ],
  )

  run_task('pe_xl::agent_install', $cm_cluster_b,
    server        => $master_host,
    install_flags => [
      '--puppet-service-ensure', 'stopped',
      "main:dns_alt_names=${dns_alt_names_csv}",
      'extension_requests:pp_application=puppet',
      'extension_requests:pp_role=pe_xl::compiler',
      'extension_requests:pp_cluster=B',
    ],
  )

  # Ensure certificate requests have been submitted
  run_command(@(HEREDOC), $agent_installer_hosts)
    /opt/puppetlabs/bin/puppet ssl submit_request
    | HEREDOC

  # TODO: come up with an intelligent way to validate that the expected CSRs
  # have been submitted and are available for signing, prior to signing them.
  # For now, waiting a short period of time is necessary to avoid a small race.
  ctrl::sleep(15)

  run_command(inline_epp(@(HEREDOC)), $master_host)
    /opt/puppetlabs/bin/puppetserver ca sign --certname <%= $agent_installer_hosts.join(',') -%>
    | HEREDOC

  run_task('pe_xl::puppet_runonce', $master_host)
  run_task('pe_xl::puppet_runonce', $all_hosts - $master_host)

  return('Installation succeeded')
}
