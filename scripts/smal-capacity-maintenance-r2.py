"""Pure validation of native storage observations. No host or guest calls."""
NODES = ('LB-NODE01', 'LB-NODE02', 'LB-NODE03')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identities(o, baseline, owners):
    require(o['clusterStatic'] == baseline, 'Cluster/pool/CSV/mirror/infrastructure identity drift')
    require(len(owners) == 24 and all(list(owners.values()).count(n) == 8 for n in NODES), 'Eight exact devices per node required')
    require(len(o['devices']) == 24 and {d['id'] for d in o['devices']} == set(owners), 'Exact device set differs')
    require(all(owners[d['id']] == d['owner'] for d in o['devices']), 'Device owner differs')
    require(set(o['nodeStates']) == set(NODES), 'Node identity set differs')
    require(o['quorumType'] == 'Majority' and o['witness'] is None, 'Quorum drift')
    require(len(o['csv']) == 4 and {c['id'] for c in o['csv']} == {c['id'] for c in baseline['csv']}
            and all(c['state'] == 'Online' and c['accessible'] is True for c in o['csv']), 'Exact CSV access required')
    require(len(o['virtualDisks']) == 5 and {v['id'] for v in o['virtualDisks']} == {v['id'] for v in baseline['virtualDisks']}
            and all(v['copies'] == 3 for v in o['virtualDisks']), 'Mirror identity/copy drift')
    require(o['physicalFreeBytes'] >= o['requiredPhysicalFreeBytes'] and o['unrelatedFailures'] == [], 'Unrelated failure/reserve violation')


def strict(o, baseline, owners):
    identities(o, baseline, owners)
    require(all(s == 'Up' for s in o['nodeStates'].values()), 'All nodes Up required')
    require(o['poolHealth'] == 'Healthy' and o['poolOperational'] == ['OK'], 'Pool Healthy/OK required')
    require(all(d['health'] == 'Healthy' and d['operational'] == ['OK'] and d['maintenance'] is False for d in o['devices']), 'All devices Healthy/OK required')
    require(all(v['health'] == 'Healthy' and v['operational'] == ['OK'] for v in o['virtualDisks']) and not o['jobs'], 'Mirrors/resync not converged')
    return 'healthy-converged'


def planned(o, baseline, owners, selected, proof, compensating=False):
    identities(o, baseline, owners)
    selected_ids = {d for d, n in owners.items() if n == selected}
    require(selected in NODES and proof['selectedNode'] == selected and proof['rpcReturned'] is True
            and proof['eightDevicesMaintenanceVerified'] is True and set(proof['deviceIds']) == selected_ids, 'Original exact maintenance proof required')
    require(all(s == 'Up' for n, s in o['nodeStates'].items() if n != selected)
            and o['nodeStates'][selected] in ('Up', 'Paused', 'Down'), 'Two Up surviving nodes required')
    allowed = {'OK', 'Degraded', 'Incomplete', 'In Service', 'InService'}
    require(o['poolHealth'] in ('Healthy', 'Warning') and o['poolOperational']
            and set(o['poolOperational']) <= allowed, 'Unknown pool failure')
    for d in o['devices']:
        if d['owner'] != selected:
            require(d['health'] == 'Healthy' and d['operational'] == ['OK'] and d['maintenance'] is False, 'Survivor degradation not admitted')
        else:
            ops = set(d['operational'])
            require(d['health'] in ('Healthy', 'Warning') and ops and ops <= {
                'OK', 'In Maintenance Mode', 'InMaintenanceMode', 'Starting Maintenance Mode',
                'StartingMaintenanceMode', 'Lost Communication', 'LostCommunication'}, 'Unknown selected device failure')
            require(d['maintenance'] is True or ops <= {'OK', 'Lost Communication', 'LostCommunication'}, 'Maintenance state unproved')
    require(all(v['health'] in ('Healthy', 'Warning') and v['operational'] and set(v['operational']) <= allowed for v in o['virtualDisks']), 'Unknown mirror failure')
    for job in o['jobs']:
        # Missing native associations are unknown, never an inferred selected-node job.
        require(compensating and job['name'] == 'Repair' and job['poolId'] == baseline['poolId']
                and job['affectedVirtualDiskIds'] and set(job['affectedVirtualDiskIds']) <= {v['id'] for v in baseline['virtualDisks']}
                and job['affectedDeviceIds'] and set(job['affectedDeviceIds']) <= selected_ids, 'Unassociated/unrelated storage job')
    return 'selected-node-maintenance-admitted'


def convergence(o, baseline, owners, selected, proof):
    try:
        return strict(o, baseline, owners)
    except ValueError:
        planned(o, baseline, owners, selected, proof, compensating=True)
        return 'pending-selected-node-resync'
