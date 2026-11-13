"""Five focused SFTP/identity guard tests. No network or native lab invocation."""
import ast
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'scripts/smal-private-powershell.py'
H={'base64':base64,'hashlib':hashlib,'json':json,'os':os,'Path':Path,'re':re,'stat':stat,'subprocess':subprocess,
   'H':{'KEY':Path('fixture-key'),'KNOWN':Path('fixture-known'),'ALIAS':'fixture-alias'}}
names={'ssh_args','run_ssh','stdin_loader','sftp_args','staging_controls','local_staged_source','run_staged_source'}
exec(compile(ast.Module(body=[n for n in ast.parse(SOURCE.read_bytes()).body if isinstance(n,ast.FunctionDef) and n.name in names],type_ignores=[]),str(SOURCE),'exec'),H)


class TransportChecks(unittest.TestCase):
    def test_pinned_ssh_and_sftp_options_no_active_stdin_delivery(self):
        ssh=H['ssh_args'](12345,'fixture','QQ==');sftp=H['sftp_args'](12345,'fixture')
        for flag in ('StrictHostKeyChecking=yes','IdentitiesOnly=yes','IdentityAgent=none','BatchMode=yes','PasswordAuthentication=no','KbdInteractiveAuthentication=no','ForwardAgent=no','ClearAllForwardings=yes'):
            self.assertIn(flag,ssh);self.assertIn(flag,sftp)
        self.assertIn('-n',ssh);self.assertEqual(sftp[sftp.index('-b')+1],'-')
        source=SOURCE.read_text();main=source[source.index('def main('):]
        self.assertNotIn('stdin_loader(source)',main);self.assertIn('run_staged_source(',main)
        self.assertIn("'scripts/read-smal-network-precreate.ps1': 300",main)

    def test_controls_exact_source_identity_and_create_only_markers(self):
        source=b'@{ok=$true}|ConvertTo-Json -Compress\n';context,prepare,invoke=H['staging_controls']('fixture-01',source,'a'*40)
        self.assertEqual(context['sourceSha256'],hashlib.sha256(source).hexdigest());self.assertEqual(context['sourceBytes'],len(source))
        self.assertIn("[IO.FileMode]::CreateNew",prepare);self.assertIn('Staging path already exists',prepare)
        self.assertIn('execution-started.json',invoke);self.assertLess(invoke.index('Staged bytes changed'),invoke.index('& ([ScriptBlock]::Create'))
        self.assertNotIn('Remove-Item',prepare+invoke)
        for script in (prepare,invoke):
            self.assertLess(len(base64.b64encode(script.encode('utf-16-le'))),16000)
            with tempfile.TemporaryDirectory() as d:
                path=Path(d)/'control.ps1';path.write_text(script)
                cmd="$t=$null;$e=$null;[Management.Automation.Language.Parser]::ParseFile('"+str(path)+"',[ref]$t,[ref]$e)|Out-Null;if($e.Count){$e|Out-String;exit 1}"
                r=subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',cmd],capture_output=True,text=True,timeout=30)
                self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        for name,data,commit in [("bad'",source,'a'*40),('fixture',b'x'*(2097152+1),'a'*40),('fixture',source,'not-a-commit')]:
            with self.assertRaises(RuntimeError):H['staging_controls'](name,data,commit)

    def test_prep_upload_uncertainty_never_invokes(self):
        source=b'# fixture\n';context,_,_=H['staging_controls']('fixture-01',source,'a'*40)
        prepared={'status':'prepared',**{k:context[k] for k in ('directory','path','sourceSha256','sourceBytes','sourceCommit')},'reservedEmptySource':True}
        for case in ('prep-failed','prep-timeout','upload-failed','upload-timeout','success'):
            calls=[];record={}
            def control(args,data,streaming,timeout):
                self.assertFalse(streaming);calls.append('control')
                if len(calls)==1:
                    if case=='prep-timeout':raise subprocess.TimeoutExpired('fixture',30)
                    return subprocess.CompletedProcess(args,1 if case=='prep-failed' else 0,json.dumps(prepared),'')
                return subprocess.CompletedProcess(args,0,'{"status":"inert"}','')
            def upload(args,**kw):
                calls.append('upload');self.assertEqual(args[0],'sftp');self.assertIsInstance(kw['input'],bytes)
                if case=='upload-timeout':raise subprocess.TimeoutExpired('fixture',60)
                return subprocess.CompletedProcess(args,1 if case=='upload-failed' else 0,b'',b'')
            with patch.dict(H,run_ssh=control,local_staged_source=lambda *a:Path('/fixture/source.ps1')),patch.object(subprocess,'run',side_effect=upload):
                if case=='success':self.assertEqual(H['run_staged_source'](12345,'fixture','fixture-01',source,'a'*40,90,record,lambda:None).returncode,0)
                else:
                    with self.assertRaises((RuntimeError,subprocess.TimeoutExpired)):H['run_staged_source'](12345,'fixture','fixture-01',source,'a'*40,90,record,lambda:None)
            self.assertEqual(calls.count('control'),2 if case=='success' else 1)
            self.assertEqual(record['staging']['executionAttempted'],case=='success')

    def test_size_matched_source_is_private_exact_and_not_overwritten(self):
        source=(ROOT/'scripts/probe-smal-private-powershell-large-20261110.ps1').read_bytes();self.assertEqual(len(source),358959)
        self.assertEqual(hashlib.sha256(source).hexdigest(),'c136334e9e289f5fe644a8fbd3b44dacab9c7dac81a3d1f08c13b050cac5acc2')
        with tempfile.TemporaryDirectory() as d,patch.object(Path,'home',return_value=Path(d)):
            path=H['local_staged_source']('fixture-01',source);self.assertEqual(path.read_bytes(),source)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600);self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode),0o700)
            with self.assertRaises(FileExistsError):H['local_staged_source']('fixture-01',source)

    def test_inert_cleanup_fingerprint_and_two_target_limit(self):
        source=(ROOT/'scripts/cleanup-smal-private-large-probe.ps1').read_text();self.assertLess(len(source.encode()),6000)
        payload=(ROOT/'scripts/probe-smal-private-powershell-large-20261110.ps1').read_bytes();encoded=H['stdin_loader'](payload)
        self.assertEqual(hashlib.sha256(encoded.encode()).hexdigest(),'e0cdd35e3a2d6e3c9d5b9ab53e62f324dadd21f96064aea1a1fb115136ab38aa')
        command="powershell.exe -c [Convert]::FromBase64String('"+encoded+"')"
        for case in ('success','too-many','changed-start','unknown-argument'):
            rows=[{'ProcessId':10111+i,'Name':'powershell.exe','CreationDate':'2026-11-10T14:24:45.1234560Z','CommandLine':command} for i in range(3 if case=='too-many' else 2)]
            if case=='unknown-argument':
                for row in rows:row['CommandLine']='powershell.exe -c harmless-unrelated'
            data=base64.b64encode(json.dumps(rows).encode()).decode()
            pre="$env:COMPUTERNAME='LocalBox-Client';$global:FixtureStops=@();$global:Scans=0;$global:FixtureRows=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+data+"'))|ConvertFrom-Json);foreach($p in $global:FixtureRows){$p.CreationDate=[datetime]$p.CreationDate}\n"
            pre+="$global:Change=$"+str(case=='changed-start').lower()+"\n"+"""
function Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec,$ErrorAction) $global:Scans++;if($global:Change -and $global:Scans -eq 2){$global:FixtureRows[0].CreationDate=$global:FixtureRows[0].CreationDate.AddSeconds(1)};return $global:FixtureRows}
function Get-Process {param($Id,$ErrorAction) $r=@($global:FixtureRows|Where-Object ProcessId -EQ $Id)[0];$p=[pscustomobject]@{Id=$Id;Handle=1;StartTime=$r.CreationDate;HasExited=$false};$p|Add-Member ScriptMethod WaitForExit {param($n)$true};$p|Add-Member ScriptMethod Dispose {};$p}
function Stop-Process {param($InputObject,[switch]$Force,$ErrorAction) $global:FixtureStops+=$InputObject.Id;$global:FixtureRows=@($global:FixtureRows|Where-Object ProcessId -NE $InputObject.Id)}
"""
            fixture=source.replace('[DateTimeOffset]::UtcNow',"[DateTimeOffset]::Parse('2026-11-10T15:00:00Z')")
            with tempfile.TemporaryDirectory() as d:
                path=Path(d)/'cleanup-fixture.ps1';path.write_text(pre+fixture+"\n@{stops=@($global:FixtureStops)}|ConvertTo-Json -Compress\n")
                result=subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-File',str(path)],capture_output=True,text=True,timeout=30)
                self.assertEqual(result.returncode,0,result.stderr)
                values=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
                self.assertEqual(len(values[-1]['stops']),2 if case=='success' else 0,result.stdout)


if __name__=='__main__':unittest.main()
