#!/usr/bin/env python3
"""Actual driver/gate routes with a fake Claude CLI; no model calls."""
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

    def test_wrong_actual_base_fails_before_dispatch(self):
        claim=self.begin();p=self.dispatch(self.head)
        self.assertEqual(p.returncode,11,p.stderr)
        self.assertFalse((self.root/'args').exists())
        self.assertNotEqual(self.gate('record','review','foreground',claim).returncode,0)
        self.assertNotEqual(self.gate('check','review').returncode,0)

    def test_actual_base_is_also_verified_when_recording(self):
        claim=self.begin();self.assertEqual(self.dispatch().returncode,0)
        (self.sd/'review.last-base').write_text(self.head+'\n')
        self.assertEqual(self.gate('record','review','foreground',claim).returncode,11)

    def test_parser_failure_keeps_the_result_for_record(self):
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

    def live_process(self):
        process = subprocess.Popen(['sleep', '30'])
        self.addCleanup(process.wait); self.addCleanup(process.kill)
        return process

    def together(self, *calls):
        workers = [subprocess.Popen(['bash', str(SCRIPTS/'review-state.sh'), *args], cwd=self.repo, env=self.env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for args in calls]
        results = []
        for worker in workers:
            out, err = worker.communicate(timeout=30)
            results.append((worker.returncode, out, err))
        return sorted(results)

    def test_each_owner_renewal_grants_a_new_round_on_the_same_session(self):
        changes = 'subject.py:1 fix\nREQUEST_CHANGES'
        self.assertIn('CAP_REACHED', self.launch_and_record(self.claim('--cap', '1'), changes).stderr)
        session = (self.sd/'review.id').read_text().strip()
        for verdict in (changes, 'APPROVE'):
            renewed = self.gate('renew', 'review', '--by', 'owner')
            self.assertEqual(renewed.returncode, 0, renewed.stderr)
            self.assertEqual(renewed.stdout, 'RENEWED thread=review attempts=0/1 authorized_by=owner\n')
            repeated = self.gate('renew', 'review', '--by', 'owner')
            self.assertEqual(repeated.returncode, 10, repeated.stdout)
            self.assertIn('RENEW_REFUSED', repeated.stderr)
            result = self.launch_and_record(self.claim(), verdict)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('CODEX_CC_REQUIRED_REVIEW APPROVE thread=review '))
        self.assertEqual((self.sd/'review.id').read_text().strip(), session)
        args = (self.root/'args').read_text().splitlines()
        self.assertEqual([args[i + 1] for i, arg in enumerate(args) if arg == '--resume'], [session, session])
        loop = (self.sd/'review.review-loop').read_text().splitlines()
        for line in ('version=1', f'base_sha={self.base}', 'spec_path=spec.md', 'cap=1', 'attempts=1', 'renewed_by=owner'):
            self.assertIn(line, loop)

    def test_renew_refuses_unless_the_cap_was_reached(self):
        missing = self.gate('renew', 'review', '--by', 'owner')
        self.assertEqual(missing.returncode, 10, missing.stderr)
        self.assertIn('INVALID_CLAIM_STATE', missing.stderr)
        token = self.claim('--cap', '1')
        self.assertIn('RENEW_REFUSED', self.gate('renew', 'review', '--by', 'owner').stderr)
        self.assertIn('CAP_REACHED', self.launch_and_record(token, 'subject.py:1 fix\nREQUEST_CHANGES').stderr)
        for owner in ('', 'first\nsecond'):
            self.assertEqual(self.gate('renew', 'review', '--by', owner).returncode, 2)
        self.assertEqual(self.gate('renew', 'review', '--by').returncode, 2)
        worker = self.live_process()
        lease = self.sd/'review.active'; lease.mkdir(); (lease/'pid').write_text(f'{worker.pid}\n')
        loop = (self.sd/'review.review-loop').read_bytes()
        live = self.gate('renew', 'review', '--by', 'owner')
        self.assertEqual(live.returncode, 10, live.stderr)
        self.assertEqual((self.sd/'review.review-loop').read_bytes(), loop)
        worker.kill(); worker.wait()
        self.assertEqual(self.gate('renew', 'review', '--by', 'owner').returncode, 0)

    def test_concurrent_state_changes_on_one_thread_have_defined_results(self):
        begin = ('begin', 'review', '--base', self.base, '--spec', 'spec.md', '--cap', '1')
        for _ in range(5):
            # Each trial starts before migration, so both callers contend for the cold lock.
            subprocess.run(['rm', '-rf', str(self.repo/'.git/codex-cc-triage')], check=True)
            results = self.together(begin, begin)
            self.assertEqual([rc for rc, _, _ in results], [0, 10], results)
            self.assertIn('PENDING:', results[1][2])
        token = re.search(r'claim=([a-f0-9]+)', results[0][1])[1]
        self.assertIn('CAP_REACHED', self.launch_and_record(token, 'subject.py:1 fix\nREQUEST_CHANGES').stderr)
        renew = ('renew', 'review', '--by', 'owner')
        results = self.together(renew, renew)
        self.assertEqual([rc for rc, _, _ in results], [0, 10], results)
        self.assertTrue(results[0][1].startswith('RENEWED '))
        self.assertIn('RENEW_REFUSED', results[1][2])

    def snapshot_fingerprint(self):
        p = self.cmd(['python3', SCRIPTS/'repo_snapshot.py', 'fingerprint', '--root', self.repo,
                      '--state-rel', '.agent-state/codex-cc-triage'])
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def write_0_7_1_thread(self, attempts, status, rounds):
        """The files 0.7.1 writes for one required thread; it never wrote .worktree."""
        self.sd.mkdir(parents=True)
        tree = self.git('rev-parse', 'HEAD^{tree}').stdout.strip()
        fp = self.snapshot_fingerprint(); token = 'a' * 40
        (self.sd/'review.review-loop').write_text(
            f'version=1\nbase_sha={self.base}\nspec_path=spec.md\ncap=5\nstart_round=0\nattempts={attempts}\n'
            'timestamp=2026-11-01T00:00:00Z\n')
        (self.sd/'review.candidate').write_text(
            f'version=1\nhead={self.head}\ntree={tree}\nfingerprint={fp}\nbase_sha={self.base}\nspec_path=spec.md\n'
            f'cap=5\nloop_start_round=0\nattempt={attempts}\nclaim_token={token}\nclaim_expires_at=9999999999\n'
            f'round_before={rounds - (status != "PENDING")}\nlog_bytes=0\ntimestamp=2026-11-01T00:00:00Z\n')
        (self.sd/'review.review-state').write_text(
            f'version=1\nstatus={status}\nverdict=NONE\ngate_eligible=false\nmode=foreground\nhead={self.head}\n'
            f'tree={tree}\nfingerprint={fp}\nbase_sha={self.base}\nspec_path=spec.md\ncap=5\nloop_start_round=0\n'
            f'claim_token={token}\nclaim_expires_at=9999999999\nround={rounds}\nreason=-\n'
            'timestamp=2026-11-01T00:00:00Z\n')
        if rounds:
            (self.sd/'review.id').write_text('11111111-1111-4111-8111-111111111111\n')
            (self.sd/'review.mode').write_text('review\n')
            (self.sd/'review.base').write_text(self.base + '\n')
            (self.sd/'review.log').write_text(''.join(
                f'\n## 2026-11-01T00:00:0{n}Z mode=review\n\n### prompt\n\nold\n' for n in range(rounds)))
        return token

    def test_a_thread_written_by_0_7_1_continues_at_its_pinned_cap(self):
        self.write_0_7_1_thread(2, 'REQUEST_CHANGES', 2)
        begun = self.gate('begin', 'review', '--base', self.base, '--spec', 'spec.md')
        self.assertEqual(begun.returncode, 0, begun.stderr)
        self.assertIn('attempt=3/5', begun.stdout)
        token = re.search(r'claim=([a-f0-9]+)', begun.stdout)[1]
        self.assertEqual(self.launch_and_record(token, 'APPROVE').returncode, 0)
        self.assertIn('--resume', (self.root/'args').read_text().splitlines())

    def test_a_pending_claim_written_by_0_7_1_dispatches_and_records(self):
        token = self.write_0_7_1_thread(1, 'PENDING', 0)
        recorded = self.launch_and_record(token, 'APPROVE')
        self.assertEqual(recorded.returncode, 0, recorded.stderr)
        self.assertTrue(recorded.stdout.rstrip().endswith('spec_path=spec.md'))

    def test_state_files_keep_the_0_7_1_format(self):
        self.assertEqual(self.launch_and_record(self.claim(), 'APPROVE').returncode, 0)
        for suffix in ('review-loop', 'candidate', 'review-state', 'approved'):
            text = (self.sd/f'review.{suffix}').read_text()
            self.assertTrue(text.startswith('version=1\n'), suffix)
            for key in ('allowance=', 'launches=', 'last_launch=', 'grants=', 'renewed_from=', 'integration'):
                self.assertNotIn(key, text, suffix)

    def test_refused_dispatch_writes_no_required_state(self):
        self.approve()
        self.begin()
        before = {p.name: p.read_bytes() for p in self.sd.iterdir()}
        (self.root/'args').unlink()
        self.prompt = 'Review without the scope header.\n'
        refused = self.dispatch()
        self.assertEqual(refused.returncode, 14, refused.stderr)
        self.assertFalse((self.root/'args').exists())
        self.assertEqual({p.name: p.read_bytes() for p in self.sd.iterdir()}, before)
        # A migrated repository never waits for the migration lock, even while another process holds it.
        holder = self.live_process()
        lock = self.repo/'.git/codex-cc-triage/migration.lock'; lock.mkdir()
        (lock/'owner').write_text(f'{holder.pid}\n')
        advisory = self.cmd(['bash', SCRIPTS/'claude-thread.sh', 'dispatch', 'ask', 'aside'], 'A question.\n')
        self.assertEqual(advisory.returncode, 0, advisory.stderr)
        self.assertEqual((lock/'owner').read_text(), f'{holder.pid}\n')

    def test_seven_rounds_unicode_marker_and_pinned_cap(self):
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
        loop = (self.sd/'review.review-loop').read_text().splitlines()
        self.assertIn('version=1', loop); self.assertIn('attempts=7', loop)
        for bad in ['0', '8']:
            self.assertEqual(self.gate('begin','review','--base',self.base,'--spec',path,'--cap',bad).returncode,2)

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
        # An established lifecycle without its loop cannot start a fresh one.
        (self.sd/'review.review-loop').unlink()
        self.assertIn('INVALID_CLAIM_STATE',self.gate('begin','review','--base',self.base,'--spec','spec.md').stderr)

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
        self.assertEqual(self.gate('record','review','foreground',claim).returncode,0)
        self.assertEqual(self.gate('check','review').returncode,0)
        self.assertEqual((self.sd/'review.review-loop').read_bytes(),loop)

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
