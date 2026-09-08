#!/usr/bin/env python3
"""Actual driver/gate routes with a fake Claude CLI; no paid calls."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tarfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
SCRIPTS=ROOT/'plugins/codex-cc-triage/scripts'


class ProductIntegrity(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.repo=self.root/'repo'; self.repo.mkdir()
        self.env=dict(os.environ,CODEX_CC_TRIAGE_PROJECT_DIR=str(self.repo),
                      CODEX_CC_TRIAGE_CLAUDE_BIN=str(ROOT/'tests/fixtures/fake-claude.sh'),
                      FAKE_CLAUDE_ARGS_LOG=str(self.root/'args'),
                      FAKE_CLAUDE_PROMPT_LOG=str(self.root/'prompt'),FAKE_CLAUDE_RESULT='APPROVE')
        for args in [('init','-q','-b','main'),('config','user.name','test'),
                     ('config','user.email','test@example.invalid')]: self.git(*args)
        (self.repo/'spec.md').write_text('VALUE must be 1\n')
        (self.repo/'subject.py').write_text('VALUE = 1\n')
        self.git('add','spec.md','subject.py'); self.git('commit','-qm','base')
        self.base=self.git('rev-parse','HEAD').stdout.strip()
        (self.repo/'subject.py').write_text('VALUE = 2\n'); self.git('commit','-qam','candidate')
        self.head=self.git('rev-parse','HEAD').stdout.strip()
        self.prompt=f'REQUIRED_REVIEW\nBASE_SHA: {self.base}\nCANDIDATE_SHA: {self.head}\nSPEC_PATH: spec.md\nReview the full candidate.\n'
        self.sd=self.repo/'.git/codex-cc-triage/threads'

    def cmd(self,args,prompt=None):
        return subprocess.run([str(x) for x in args],cwd=self.repo,env=self.env,
                              input=prompt,text=True,capture_output=True,timeout=30)

    def git(self,*args):
        p=self.cmd(['git',*args]);self.assertEqual(p.returncode,0,p.stderr);return p

    def gate(self,*args): return self.cmd(['bash',SCRIPTS/'review-state.sh',*args])

    def begin(self):
        p=self.gate('begin','review','--base',self.base,'--spec','spec.md','--cap','3')
        self.assertEqual(p.returncode,0,p.stderr)
        return re.search(r'claim=([a-f0-9]+)',p.stdout)[1]

    def dispatch(self,base=None):
        return self.cmd(['bash',SCRIPTS/'claude-thread.sh','dispatch','review','review',base or self.base],self.prompt)

    def approve(self):
        claim=self.begin();p=self.dispatch();self.assertEqual(p.returncode,0,p.stderr)
        p=self.gate('record','review','foreground',claim);self.assertEqual(p.returncode,0,p.stderr)

    def test_wrong_actual_base_fails_before_paid_dispatch(self):
        claim=self.begin();p=self.dispatch(self.head)
        self.assertEqual(p.returncode,11,p.stderr)
        self.assertFalse((self.root/'args').exists())
        self.assertNotEqual(self.gate('record','review','foreground',claim).returncode,0)
        self.assertNotEqual(self.gate('check','review').returncode,0)

    def test_actual_base_is_also_verified_when_recording(self):
        claim=self.begin();self.assertEqual(self.dispatch().returncode,0)
        (self.sd/'review.last-base').write_text(self.head+'\n')
        self.assertEqual(self.gate('record','review','foreground',claim).returncode,11)

    def test_new_negative_reply_revokes_approval(self):
        self.approve();self.assertEqual(self.gate('check','review').returncode,0)
        self.env['FAKE_CLAUDE_RESULT']='REQUEST_CHANGES'
        p=self.cmd(['bash',SCRIPTS/'claude-thread.sh','reply','review'],'Re-evaluate the candidate.\n')
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertIn('REQUEST_CHANGES',p.stdout)
        self.assertNotEqual(self.gate('check','review').returncode,0)
        log=(self.sd/'review.log').read_text()
        self.assertIn('APPROVE',log);self.assertIn('REQUEST_CHANGES',log)

    def test_partial_staging_retains_both_patches(self):
        (self.repo/'subject.py').write_text('VALUE = 3\n');self.git('add','subject.py')
        (self.repo/'subject.py').write_text('VALUE = 2\n')
        p=self.cmd(['python3',SCRIPTS/'repo_snapshot.py','context','--root',self.repo,
                    '--state-rel','.agent-state/codex-cc-triage','--output',self.root/'context','--base-ref','HEAD'])
        self.assertEqual(p.returncode,0,p.stderr)
        context=(self.root/'context').read_text()
        staged,unstaged=context.split('## staged: HEAD to index\n')[1].split('## unstaged: index to worktree\n')
        self.assertIn('+VALUE = 3',staged);self.assertIn('-VALUE = 3',unstaged)
        self.assertIn('+VALUE = 2',unstaged)

    def test_dead_lease_recovery_preserves_history_and_resumes(self):
        self.approve();session=(self.sd/'review.id').read_text();log=(self.sd/'review.log').read_bytes()
        claim=self.begin()
        dead=subprocess.Popen(['true']);dead.wait()
        lease=self.sd/'review.active';lease.mkdir();(lease/'pid').write_text(str(dead.pid)+'\n')
        p=self.gate('abort','review','tool-failure',claim)
        self.assertEqual(p.returncode,10,p.stderr);self.assertIn('ABORTED',p.stderr)
        self.assertEqual((self.sd/'review.id').read_text(),session)
        self.assertEqual((self.sd/'review.log').read_bytes(),log)
        self.approve()
        self.assertEqual((self.sd/'review.id').read_text(),session)
        self.assertEqual(self.gate('check','review').returncode,0)

    def test_capabilities_cached_and_explicit_effort_capability_checked(self):
        help_log=self.root/'help-calls'
        self.env['FAKE_CLAUDE_HELP_LOG']=str(help_log)
        self.assertEqual(self.dispatch().returncode,0)
        self.assertEqual(self.dispatch().returncode,0)
        self.assertEqual(help_log.read_text().splitlines(),['help'])
        self.env['CODEX_CC_TRIAGE_EFFORT']='high'
        p=self.dispatch();self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(len(help_log.read_text().splitlines()),2)
        args=(self.root/'args').read_text().splitlines()
        self.assertEqual(args[args.index('--effort')+1],'high')
        self.env['CODEX_CC_TRIAGE_REFRESH_CAPABILITIES']='1'
        self.env['FAKE_CLAUDE_MISSING_FLAG']='--effort'
        self.assertNotEqual(self.dispatch().returncode,0)


    def test_reset_archives_session_and_log_before_clearing(self):
        self.approve()
        session=(self.sd/'review.id').read_bytes()
        log=(self.sd/'review.log').read_bytes()
        p=self.cmd(['bash',SCRIPTS/'claude-thread.sh','new','review'])
        self.assertEqual(p.returncode,0,p.stderr)
        archives=list(self.sd.glob('review.archive.*'))
        self.assertEqual(len(archives),1)
        self.assertTrue(archives[0].is_file())
        with tarfile.open(archives[0]) as archive:
            self.assertEqual(archive.extractfile('review.id').read(),session)
            self.assertEqual(archive.extractfile('review.log').read(),log)
        self.assertFalse((self.sd/'review.id').exists())
        self.assertNotEqual(self.gate('check','review').returncode,0)

if __name__=='__main__': unittest.main()
