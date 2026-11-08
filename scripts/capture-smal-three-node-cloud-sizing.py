"""Read-only current VM/disk/SKU evidence and public disk retail rates. No writes to Azure."""
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-29/three-node-premium-cloud-sizing.json'
SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
RG = 'rg-localbox-nodes-san-1'


def az(args):
    result = subprocess.run(['az', *args, '--subscription', SUB, '--only-show-errors', '--output', 'json'], check=True, capture_output=True, text=True, timeout=120)
    return json.loads(result.stdout)


def main():
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'status': 'pending-read-only', 'azureMutationPerformed': False}
    with OUT.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    try:
        record['vm'] = az(['vm', 'show', '-g', RG, '-n', 'LocalBox-Client', '--query', '{id:id,location:location,vmSize:hardwareProfile.vmSize,luns:storageProfile.dataDisks[].lun,osDiskId:storageProfile.osDisk.managedDisk.id}'])
        record['disks'] = az(['disk', 'list', '-g', RG, '--query', '[].{id:id,name:name,diskSizeGB:diskSizeGB,sku:sku.name,state:diskState,managedBy:managedBy}'])
        record['sku'] = az(['vm', 'list-skus', '--location', 'southafricanorth', '--size', 'Standard_E32s_v6', '--resource-type', 'virtualMachines', '--query', '[].{name:name,capabilities:capabilities[?name==`MemoryGB` || name==`vCPUs` || name==`MaxDataDiskCount` || name==`PremiumIO`],restrictions:restrictions}'])
        expression = "armRegionName eq 'southafricanorth' and serviceName eq 'Storage' and priceType eq 'Consumption' and (contains(meterName, 'S15') or contains(meterName, 'S30') or contains(meterName, 'P15') or contains(meterName, 'P30') or contains(meterName, 'P40'))"
        url = 'https://prices.azure.com/api/retail/prices?$filter=' + urllib.parse.quote(expression)
        pages = []; items = []
        while url:
            if not url.startswith('https://prices.azure.com/api/retail/prices'): raise RuntimeError('Unexpected public pricing continuation host')
            with urllib.request.urlopen(url, timeout=60) as response: page = json.load(response)
            pages.append(url); items.extend(page['Items']); url = page.get('NextPageLink')
            if len(pages) > 10: raise RuntimeError('Unexpected pricing traversal size')
        record['pricing'] = {'currency': 'USD', 'pages': pages, 'items': items, 'complete': True,
                             'contractQuote': False, 'taxFxTrafficAndOperationChargesIncluded': False}
        record['status'] = 'complete-read-only'
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        record['status'] = 'failed-preserve-before-retry'; record['errorType'] = type(error).__name__
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    OUT.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'status': record['status'], 'receipt': str(OUT.relative_to(ROOT)), 'diskCount': len(record.get('disks', [])), 'pricingItemCount': len(record.get('pricing', {}).get('items', []))}, indent=2))
    return 0 if record['status'] == 'complete-read-only' else 2


if __name__ == '__main__':
    raise SystemExit(main())
