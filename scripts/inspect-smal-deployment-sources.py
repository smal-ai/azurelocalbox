"""Capture public pinned deployment references/rates for static review only."""
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
import io

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-28/upstream-review'
REPO = 'https://api.github.com/repos/Azure/azure-quickstart-templates'
TEMPLATE_PATH = 'quickstarts/microsoft.azurestackhci/create-cluster'


def get(url):
    origin = urllib.parse.urlsplit(url)
    if origin.scheme != 'https' or origin.hostname not in {'api.github.com', 'raw.githubusercontent.com', 'prices.azure.com', 'www.powershellgallery.com', 'powershellgallery.com'} or origin.username or origin.password:
        raise RuntimeError('Only exact public HTTPS source origins are permitted')
    request = urllib.request.Request(url, headers={'User-Agent': 'AzureLocalBox-static-source-review', 'Accept': '*/*'})
    with urllib.request.urlopen(request, timeout=90) as response:
        if urllib.parse.urlsplit(response.url).scheme != 'https':
            raise RuntimeError('Source redirected away from HTTPS')
        return response.read()


def save(name, data):
    path = OUT / name
    with path.open('xb') as stream:
        stream.write(data)
    return {'path': str(path.relative_to(ROOT)), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def main():
    OUT.mkdir(exist_ok=False)
    record = {'atUtc': datetime.now(timezone.utc).isoformat(), 'status': 'pending-static-review', 'files': [],
              'moduleImportedOrExecuted': False, 'azureApplyPerformed': False}
    save('capture-started.json', (json.dumps(record, indent=2) + '\n').encode())
    record['files'].append(save('quickstart-commit.json', get(REPO + '/commits?path=' + TEMPLATE_PATH + '&per_page=1')))
    commits = json.loads((OUT / 'quickstart-commit.json').read_text())
    commit = commits[0]['sha']; record['quickstartCommit'] = commit
    for name in ['azuredeploy.json', 'azuredeploy.parameters.json']:
        url = 'https://raw.githubusercontent.com/Azure/azure-quickstart-templates/' + commit + '/' + TEMPLATE_PATH + '/' + name
        record['files'].append({**save(name, get(url)), 'url': url})
    rate_url = "https://prices.azure.com/api/retail/prices?$filter=serviceName%20eq%20%27Azure%20Local%27"
    rates = get(rate_url)
    record['files'].append({**save('azure-local-retail-rates.json', rates), 'url': rate_url})
    if json.loads(rates).get('NextPageLink'):
        raise RuntimeError('Pricing response requires traversal; do not pretend complete')
    gallery_url = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id=%27AsHciADArtifactsPreCreationTool%27"
    metadata = get(gallery_url)
    record['files'].append({**save('ad-module-catalogue.xml', metadata), 'url': gallery_url})
    ns = {'a': 'http://www.w3.org/2005/Atom', 'm': 'http://schemas.microsoft.com/ado/2007/08/dataservices/metadata',
          'd': 'http://schemas.microsoft.com/ado/2007/08/dataservices'}
    feed = ET.fromstring(metadata)
    if any(link.get('rel') == 'next' for link in feed.findall('a:link', ns)):
        raise RuntimeError('Module catalogue incomplete; review continuation before selecting a version')
    candidates = []
    for entry in feed.findall('a:entry', ns):
        p = entry.find('m:properties', ns)
        if p is None: continue
        def field(name): return p.findtext('d:' + name, namespaces=ns)
        if field('IsLatestVersion') == 'true' and field('IsPrerelease') != 'true':
            candidates.append((entry, field('Version'), field('PackageHash'), field('PackageHashAlgorithm')))
    if len(candidates) != 1: raise RuntimeError('Latest stable module selection ambiguous')
    entry, version, expected, algorithm = candidates[0]
    if algorithm != 'SHA512': raise RuntimeError('Unexpected gallery hash algorithm')
    url = entry.find('a:content', ns).get('src')
    package = get(url)
    if base64.b64encode(hashlib.sha512(package).digest()).decode() != expected:
        raise RuntimeError('Gallery package hash mismatch')
    record['adModule'] = {'name': 'AsHciADArtifactsPreCreationTool', 'version': version,
                          'packageSha512MatchesGallery': True, 'imported': False, 'executed': False}
    record['files'].append({**save('ad-precreation.' + version + '.nupkg', package), 'url': url})
    with zipfile.ZipFile(io.BytesIO(package)) as archive:
        for name in archive.namelist():
            # Retain code/manifests for review, never extract arbitrary paths or binaries.
            if name.lower().endswith(('.psm1', '.psd1', '.nuspec')) and '/' not in name and '\\' not in name:
                record['files'].append(save('ad-module-' + name, archive.read(name)))
    record['status'] = 'captured-for-static-review-not-apply'
    save('source-receipt.json', (json.dumps(record, indent=2) + '\n').encode())
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
