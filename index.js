require('array.prototype.find');

const Promise = require('promise');
const exec = require('child-process-promise').exec;
const cli = require('command-line-args')([
    { name: 'dc', description: 'The datacentre in which to provision a new VM', type: String },
    { name: 'vm', description: '[Optional] Specify if the vm  to be provisioned is part of a clustered installation', type: String },
    { name: 'help' }
]);

var args = parseCommandLineArgs();

if (!args) {
    return;
}

getDeployedVMData()
    .then(function(vmData) {
        args.vmData = vmData;
    })
    .then(getHostsInDataCentre)
    .then(getHostsData)
    .then(filterHosts)
    .then(rankHosts)
    .then(function(hosts) {
        if (hosts.length == 0) {
            throw new Error('No applicable host');
        } else {
            var host = hosts[0].name;
            var vmId = getUniqueVmId(args.vmData.concat());

            console.log(vmId !== null ? vmId + ' ' + host : host);
            process.exit(0);

            function getUniqueVmId(vmData) {
                if(!args.vm && vmData.length == 0) return null; // Not a clustered VM, no need for a unique id

                var id = 0; // Indexed from 1 (incremenented in the while loop below)
                var duplicateId = true;

                while(duplicateId) {
                    id++;
                    duplicateId = vmData.find(function(data) {
                        return data.id == id;
                    });
                }

                return id;
            }
        }
    })
    .catch(function(err) {
        console.log(err.stack);

        process.exit(1);
    });

function getDeployedVMData() {
    return args.vm ? govc('ls', ['/' + args.dc + '/vm']).then(getVmData) : Promise.resolve([]);

    function getVmData(vmData) {
        var vms = [];
        var elements = vmData.elements ? vmData.elements : [];

        for(var i = 0; i < elements.length; i++) {
            try {
                // Look for vm names which start with the command line provided vm name and end with some integer
                // E.g if --vm=myVM we're looking for vm names like "myVM1", "myVM2" etc
                var data = elements[i].Object.Summary;
                var vmName = data.Config.Name;
                var vmId = parseInt(vmName.substring(args.vm.length));

                if (vmName.indexOf(args.vm) == 0 && !isNaN(vmId)) {
                    // Id is extracted from the vm name, vmwareId is a unique id assigned by vmware
                    vms.push({ id: vmId,  vmwareId: data.Vm.Value })
                }
            } catch (e) {}
        }

        return vms;
    }
}

function getHostsInDataCentre() {
    return govc('ls', ['/' + args.dc + '/host']).then(getHostNames)

    function getHostNames(hostData) {
        if (!hostData || !hostData.elements || hostData.elements.length == 0) {
            throw new Error('No hosts available in data "' + args.dc + '" centre');
        }

        return hostData.elements.map(function(host) {
            return host.Object.Name;
        });
    }
}

function getHostsData(hosts) {
    return Promise.all(hosts.map(getHostInfo));

    function getHostInfo(host) {
        return govc('host.info', ['-dc ' + args.dc, host]).then(extractSummary);

        function extractSummary(data) {
            var hostData = data.HostSystems[0]; // There can be more than one?!
            var summary = hostData.Summary;
            var quickStats = summary.QuickStats;
            var memoryUsage = quickStats.OverallMemoryUsage / 1024 / 1024; // Convert bytes into MBs

            return {
                name: summary.Config.Name,
                cpu: summary.Hardware.CpuMhz,
                cpuUsage: quickStats.OverallCpuUsage,
                availableCpu: summary.Hardware.CpuMhz - quickStats.OverallCpuUsage,
                memory: summary.Hardware.MemorySize,
                memoryUsage: memoryUsage,
                availableMemory: memoryUsage - quickStats.OverallMemoryUsage,
                vmIds: hostData.Vm.map(function(vmData) {
                    return vmData.Value;
                })
            }
        }
    }
}

function filterHosts(hosts) {
    return args.vmData.length > 0 ? filterHostsWithVms(args.vmData) : hosts;

    function filterHostsWithVms(vmData) {
        return hosts.filter(function(host) {
            return vmData.every(function(vmData) {
                return host.vmIds.indexOf(vmData.vmwareId) == -1;
            });
        });
    }
}

function rankHosts(hosts) {
    hosts.sort(function(host1, host2) {
        // Sort hosts by available memory.  If the memory available to either host does not differ by more than 2GB
        // fallback to sorting against the CPU utilisation.
        var memoryDifference = host1.availableMemory - host2.availableMemory;

        if (Math.abs(memoryDifference) < 2048) {
            return host1.availableCpu - host2.availableCpu;
        } else {
            return memoryDifference;
        }
    });

    return hosts;
}

function govc(cmd, args) {
    var govcCmd = 'govc ' + cmd + ' -json ' + args.join(' ');

    // govc command with json flag returns A LOT of data (Thus the huge max buffer)
    return exec(govcCmd, { maxBuffer: 1024 * 1024 * 2 }).then(function(result) { // Todo: Stop pretending this could never error
        return JSON.parse(result.stdout);
    });
}

function parseCommandLineArgs() {
    try {
        var args = cli.parse();

        if (args.help) {
            printHelp();
        } else if (!args.dc) {
            printHelp('Missing required argument --dc');
        } else {
            return args;
        }
    } catch(e) {
        console.log(e.message);

        printHelp();
    }

    function printHelp(message) {
        if (message) {
            console.log(message);
        }

        console.log(cli.getUsage({
            title: 'VM Provisioning Script',
            description: 'Script which determines the most suitable host for a new virtual machine',
            synopsis: [
                '$ node index.js [[bold]{--dc} [underline]{string}]',
                '$ node index.js [[bold]{--dc} [underline]{string}] [bold]{--vm} [underline]{string}'
            ]
        }));
    }
}
