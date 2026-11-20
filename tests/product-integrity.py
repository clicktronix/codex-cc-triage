#!/usr/bin/env python3
"""Actual driver/gate routes with a fake Claude CLI; no paid calls."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tarfile
import unittest
from concurrent.futures import ThreadPoolExecutor

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

    def test_parser_failure_keeps_the_paid_result_for_record(self):
        claim = self.begin()
        self.assertEqual(self.dispatch().returncode, 0)
        broken = self.root/'python-stub'
        broken.write_text('#!/bin/sh\ncase "$2" in *.last-result) exit 42 ;; esac\nexec python3 "$@"\n')
        broken.chmod(0o755)
        self.env['CODEX_CC_TRIAGE_PYTHON_BIN'] = str(broken)
        result = self.gate('record','review','foreground',claim)
        self.assertEqual(result.returncode,7,result.stderr)
        self.assertIn('status=PENDING\n',(self.sd/'review.review-state').read_text())
        del self.env['CODEX_CC_TRIAGE_PYTHON_BIN']
        self.assertEqual(self.gate('record','review','foreground',claim).returncode,0)
        self.assertEqual((self.root/'args').read_text().splitlines().count('-p'),1)

    def test_rejected_advisory_reply_preserves_required_approval(self):
        self.approve();self.assertEqual(self.gate('check','review').returncode,0)
        self.env['FAKE_CLAUDE_RESULT']='subject.py:1 change this\nREQUEST_CHANGES'
        p=self.cmd(['bash',SCRIPTS/'claude-thread.sh','reply','review'],'Re-evaluate the candidate.\n')
        self.assertEqual(p.returncode,10,p.stderr)
        self.assertEqual(self.gate('check','review').returncode,0)
        claim=self.begin()
        self.assertEqual(self.dispatch().returncode,0)
        self.assertIn('REQUEST_CHANGES',self.gate('record','review','foreground',claim).stderr)
        self.assertNotEqual(self.gate('check','review').returncode,0)
        log=(self.sd/'review.log').read_text()
        self.assertIn('APPROVE',log);self.assertIn('REQUEST_CHANGES',log)

    def claim(self, *flags, spec='spec.md'):
        result = self.gate('begin', 'review', '--base', self.base, '--spec', spec, *flags)
        self.assertEqual(result.returncode, 0, result.stderr)
        return re.search(r'claim=([a-f0-9]+)', result.stdout)[1]

    def launch_and_record(self, token, result):
        self.env['FAKE_CLAUDE_RESULT'] = result
        header = self.gate('header', 'review')
        self.assertEqual(header.returncode, 0, header.stderr)
        self.prompt = header.stdout + 'Review the candidate.\n'
        dispatched = self.dispatch()
        self.assertEqual(dispatched.returncode, 0, dispatched.stderr)
        return self.gate('record', 'review', 'foreground', token)

    def test_seven_calls_unicode_marker_and_pinned_cap(self):
        path = 'Документы/План работ.md'
        spec = self.repo/path
        spec.parent.mkdir()
        spec.write_text('Verify acceptance.\n')
        (self.repo/'Словарь').write_text('entry\n')
        self.git('add', '.'); self.git('commit','-qm','Add review spec')
        for n in range(7):
            token = self.claim(spec=path)
            result = self.launch_and_record(token, 'Словарь:1 incorrect\nREQUEST_CHANGES' if n < 6 else 'APPROVE')
            if n < 6:
                self.assertIn('REQUEST_CHANGES', result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.rstrip().endswith('spec_path='+path))
        self.assertIn('launches=7\n', (self.sd/'review.review-loop').read_text())
        for bad in ['0', '8']:
            self.assertEqual(self.gate('begin','review','--base',self.base,'--spec',path,'--cap',bad).returncode,2)

    def test_failure_spends_one_call_and_grants_are_exact(self):
        token = self.claim('--cap','1')
        self.env['FAKE_CLAUDE_SILENT_FAIL'] = '1'
        self.assertEqual(self.dispatch().returncode, 3)
        self.assertIn('ALREADY_DISPATCHED', self.dispatch().stderr)
        del self.env['FAKE_CLAUDE_SILENT_FAIL']
        self.assertIn('ABORTED', self.gate('abort','review','dispatch-failure',token).stderr)
        self.assertIn('CAP_REACHED', self.gate('begin','review','--base',self.base,'--spec','spec.md').stderr)
        args = ('renew','review','--by','Иван (owner), #7','--rounds','3','--grant','decision-1')
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = [pool.submit(self.gate, *args) for _ in range(2)]
            for result in results:
                renewal = result.result()
                self.assertIn('remaining=3', renewal.stdout, renewal.stderr)
        self.assertEqual(self.gate('mode','review').stdout.strip(), 'required')
        self.assertEqual(self.gate('advisory-check','review').returncode, 10)
        for i in range(3):
            state = self.launch_and_record(self.claim(), 'subject.py:1 fix it\nREQUEST_CHANGES')
            self.assertIn('CAP_REACHED' if i == 2 else 'REQUEST_CHANGES', state.stderr)
        self.assertIn('remaining=0',self.gate(*args).stdout)
        self.assertIn('GRANT_MISMATCH',self.gate('renew','review','--by','owner','--grant','decision-1').stderr)
        self.assertEqual((self.root/'args').read_text().splitlines().count('-p'),4)
        self.assertIn('remaining=1',self.gate('renew','review','--by','owner').stdout)
        empty = self.launch_and_record(self.claim(), 'Could not connect to 127.0.0.1:5432.\nREQUEST_CHANGES')
        self.assertIn('NO_FINDINGS',empty.stderr)
        loop = (self.sd/'review.review-loop').read_text().splitlines()
        self.assertIn('cap=1',loop); self.assertIn('attempts=0',loop); self.assertIn('launches=1',loop)

    def test_interrupted_first_claim_is_recoverable(self):
        token = self.claim('--cap','1')
        candidate = self.sd/'review.candidate'
        journal = self.sd/'review.claim-prep'
        # Interrupt publication after the durable journal, before the first loop.
        journal.write_bytes(candidate.read_bytes())
        for suffix in ('candidate', 'review-state', 'review-loop'):
            (self.sd/('review.'+suffix)).unlink()
        self.assertEqual(self.claim(), token)
        self.assertEqual(self.launch_and_record(token, 'APPROVE').returncode, 0)
        # Missing accounting in an established lifecycle cannot mint a fresh grant.
        (self.sd/'review.review-loop').unlink()
        self.assertIn('INVALID_CLAIM_STATE',self.gate('begin','review','--base',self.base,'--spec','spec.md').stderr)

    def test_legacy_first_reservation_and_approval_remain_usable(self):
        self.sd.mkdir(parents=True)
        loop = self.sd/'review.review-loop'
        loop.write_text(f'version=1\nbase_sha={self.base}\nspec_path=spec.md\ncap=1\nstart_round=0\nattempts=1\n')
        token=self.claim()
        self.assertIn('allowance=1\n',loop.read_text())
        self.assertEqual(self.launch_and_record(token,'APPROVE').returncode,0)
        # V1 approvals keep the original marker and the original launch ceiling.
        legacy = f'version=1\nbase_sha={self.base}\nspec_path=spec.md\ncap=1\nstart_round=0\nattempts=1\n'
        loop.write_text(legacy)
        self.assertEqual(self.gate('check','review').returncode,0)
        self.assertIn('CAP_REACHED',self.gate('begin','review','--base',self.base,'--spec','spec.md').stderr)

    def test_existing_v1_session_can_launch_its_unstarted_pending_round(self):
        self.approve()
        claim = self.begin()
        loop = self.sd/'review.review-loop'
        loop.write_text(f'version=1\nbase_sha={self.base}\nspec_path=spec.md\ncap=3\nstart_round=0\nattempts=2\n')
        self.assertTrue((self.sd/'review.mode').is_file())
        os.utime(self.sd/'review.mode', (1000000,1000000))
        self.assertEqual(self.launch_and_record(claim,'APPROVE').returncode,0)
        self.assertIn('launches=2\n',loop.read_text())

    def test_legacy_pending_with_a_newer_started_worker_preserves_history(self):
        token = self.claim('--cap','1')
        loop=self.sd/'review.review-loop'
        loop.write_text(f'version=1\nbase_sha={self.base}\nspec_path=spec.md\ncap=1\nstart_round=0\nattempts=1\n')
        os.utime(self.sd/'review.candidate',(1000000,1000000))
        (self.sd/'review.mode').write_text('review\n')
        self.assertIn('ALREADY_DISPATCHED',self.dispatch().stderr)
        self.assertFalse((self.root/'args').exists())
        self.assertIn('ABORTED',self.gate('abort','review','tool-failure',token).stderr)
        self.assertIn('CAP_REACHED',self.gate('begin','review','--base',self.base,'--spec','spec.md').stderr)

    def test_interrupted_renewal_preserves_the_granted_balance(self):
        self.launch_and_record(self.claim('--cap','1'),'subject.py:1 fix\nREQUEST_CHANGES')
        state = self.sd/'review.review-state'
        old_state = state.read_bytes()
        self.assertIn('remaining=3',self.gate('renew','review','--by','owner','--rounds','3').stdout)
        state.write_bytes(old_state)
        self.assertIn('RENEW_REFUSED',self.gate('renew','review','--by','another owner').stderr)
        self.assertIn('status=RENEWED\n',state.read_text())
        self.claim()
        self.assertIn('allowance=3\n',(self.sd/'review.review-loop').read_text())

    def test_integrated_candidate_retries_only_technical_failures(self):
        token=self.claim('--cap','1')
        self.assertEqual(self.launch_and_record(token,'APPROVE').returncode,0)
        self.git('checkout','-qb','target',self.base)
        (self.repo/'target.txt').write_text('target\n')
        self.git('add','target.txt'); self.git('commit','-qm','Advance target')
        self.git('checkout','-q','main'); self.git('merge','--no-ff','-qm','Integrate target','target')
        merge=self.git('rev-parse','HEAD').stdout.strip()
        self.assertIn('remaining=1',self.gate('renew','review','--by','owner','--grant','integrate').stdout)
        token=self.claim('--integration')
        self.assertIn('attempt=0\n',(self.sd/'review.candidate').read_text())
        self.assertIn('NO_FINDINGS',self.launch_and_record(token,'REQUEST_CHANGES').stderr)
        self.git('commit','--amend','-qm','A different merge')
        self.assertIn('remaining=1',self.gate('renew','review','--by','owner','--grant','retry').stdout)
        begin=('begin','review','--base',self.base,'--spec','spec.md','--integration')
        self.assertIn('INTEGRATION_REFUSED',self.gate(*begin).stderr)
        self.git('checkout','--detach',merge)
        self.assertIn('CAP_REACHED',self.launch_and_record(self.claim('--integration'),'subject.py:1 fix\nREQUEST_CHANGES').stderr)
        self.assertIn('remaining=1',self.gate('renew','review','--by','owner','--grant','fix').stdout)
        self.assertIn('INTEGRATION_REFUSED',self.gate(*begin).stderr)
        self.assertEqual(self.launch_and_record(self.claim(),'APPROVE').returncode,0)

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

    def test_broken_python_is_reported_before_dispatch_changes_state(self):
        self.approve()
        before={p.name:p.read_bytes() for p in self.sd.iterdir()}
        (self.root/'args').unlink()
        interpreter=self.root/'broken-python'
        interpreter.write_text('#!/bin/sh\necho "broken interpreter" >&2\nexit 127\n')
        interpreter.chmod(0o755)
        self.env['CODEX_CC_TRIAGE_PYTHON_BIN']=str(interpreter)
        for args in [('dispatch','review','review',self.base),('reply','review'),
                     ('dispatch','plan','fresh')]:
            with self.subTest(args=args):
                p=self.cmd(['bash',SCRIPTS/'claude-thread.sh',*args],self.prompt)
                self.assertEqual(p.returncode,9,p.stderr)
                self.assertIn('Python 3.8 or newer',p.stderr)
                self.assertFalse((self.root/'args').exists())
                self.assertEqual({p.name:p.read_bytes() for p in self.sd.iterdir()},before)
        self.assertEqual(self.cmd(['bash',SCRIPTS/'claude-thread.sh','status']).returncode,0)
        self.assertEqual(self.cmd(['bash',SCRIPTS/'claude-thread.sh','new','review']).returncode,0)

    def test_first_dispatch_with_missing_python_creates_no_state(self):
        self.env['CODEX_CC_TRIAGE_PYTHON_BIN']=str(self.root/'missing-python')
        p=self.dispatch()
        self.assertEqual(p.returncode,9,p.stderr)
        self.assertFalse(self.sd.exists())
        self.assertFalse((self.repo/'.agent-state').exists())
        self.assertFalse((self.root/'args').exists())

    def test_archived_only_thread_is_visible_without_modifying_history(self):
        self.approve()
        self.assertEqual(self.cmd(['bash',SCRIPTS/'claude-thread.sh','new','review']).returncode,0)
        archives=list(self.sd.glob('review.archive.*'))
        self.assertEqual(len(archives),1)
        before={p.name:p.read_bytes() for p in self.sd.iterdir()}
        for args in [('status',),('status','review')]:
            p=self.cmd(['bash',SCRIPTS/'claude-thread.sh',*args])
            self.assertEqual(p.returncode,0,p.stderr)
            self.assertIn(f'Archives: 1 file(s), {archives[0].stat().st_size} bytes',p.stdout)
            self.assertIn(str(self.sd),p.stdout)
            self.assertEqual({p.name:p.read_bytes() for p in self.sd.iterdir()},before)
        self.assertEqual(self.cmd(['bash',SCRIPTS/'claude-thread.sh','status','absent']).returncode,6)

    def test_corrupt_claim_can_recover_from_intact_snapshot_without_reset(self):
        claim=self.begin()
        candidate=self.sd/'review.candidate'; saved=candidate.read_text()
        loop=(self.sd/'review.review-loop').read_bytes()
        candidate.write_text(saved.replace(claim,'invalid-token'))
        p=self.gate('record','review','foreground',claim)
        self.assertEqual(p.returncode,10,p.stderr)
        self.assertIn('INVALID_CLAIM_STATE',p.stderr)
        self.assertEqual((self.sd/'review.review-loop').read_bytes(),loop)
        candidate.write_text(saved)
        self.assertEqual(self.dispatch().returncode,0)
        charged=(self.sd/'review.review-loop').read_bytes()
        self.assertIn(b'launches=1\n',charged)
        self.assertEqual(self.gate('record','review','foreground',claim).returncode,0)
        self.assertEqual(self.gate('check','review').returncode,0)
        self.assertEqual((self.sd/'review.review-loop').read_bytes(),charged)

    def test_mutating_reviewer_never_publishes_a_completed_result(self):
        claim=self.begin()
        self.env.update(FAKE_CLAUDE_MUTATE='1',FAKE_CLAUDE_PROJECT_DIR=str(self.repo))
        p=self.dispatch()
        self.assertEqual(p.returncode,5,p.stderr)
        self.assertFalse((self.sd/'review.last-result').exists())
        self.assertFalse((self.sd/'review.last-fingerprint').exists())
        self.assertNotEqual(self.gate('check','review').returncode,0)
        (self.repo/'mutable.txt').unlink()
        p=self.gate('abort','review','tool-failure',claim)
        self.assertEqual(p.returncode,10,p.stderr)
        self.assertIn('ABORTED',p.stderr)

if __name__=='__main__': unittest.main()
