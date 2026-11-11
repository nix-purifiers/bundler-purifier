# SPDX-License-Identifier: MIT
"""Genuine Bundler 0.9 Git and implicit-source snapshot boundaries."""
import os,json,pathlib,subprocess,signal,hashlib,time,argparse,tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('sdk',type=pathlib.Path)
parser.add_argument('repository',type=pathlib.Path)
parser.add_argument('catalog',type=pathlib.Path)
parser.add_argument('--results',type=pathlib.Path)
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]
work=args.results.resolve() if args.results else pathlib.Path(tempfile.mkdtemp(prefix='bundler09-sources-'))
work.mkdir(exist_ok=args.results is None)
sdk=args.sdk
views=[dict(repository=str(args.repository),catalog=str(args.catalog))]
receipt=dict(complete=False,scope='native Git and implicit source observer boundaries only',commands=[]);deadline=time.monotonic()+180

def run(label,argv,cwd,env=None):
 out=work/(label+'.stdout');err=work/(label+'.stderr')
 with out.open('wb') as o,err.open('wb') as e:
  p=subprocess.Popen(list(map(str,argv)),cwd=cwd,env=env,stdout=o,stderr=e,start_new_session=True)
  try: code=p.wait(timeout=min(45,max(1,deadline-time.monotonic())))
  except BaseException:
   os.killpg(p.pid,signal.SIGKILL);p.wait();raise
 assert len(receipt['commands']) < 12
 receipt['commands'].append(dict(label=label,argv=list(map(str,argv)),exit=code,stdoutSha256=hashlib.sha256(out.read_bytes()).hexdigest(),stderrSha256=hashlib.sha256(err.read_bytes()).hexdigest()))
 (work/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 assert code==0,err.read_text()[-2500:]
 return out.read_text()
repo=work/'git-leaf';(repo/'lib').mkdir(parents=True)
(repo/'lib/git_leaf.rb').write_text('module GitLeaf; def self.answer; 17; end; end\n')
(repo/'git_leaf.gemspec').write_text('Gem::Specification.new {|s| s.name="git_leaf"; s.version="1.0.0"; s.authors=["fixture"]; s.summary="native git fixture"; s.files=["lib/git_leaf.rb"] }\n')
for label,args in [('init',['init','-q','-b','main']),('add',['add','.']),('commit',['-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture'])]:run('git-'+label,['git',*args],repo)
for mode in ['implicit','git']:
 project=work/mode;project.mkdir()
 manifest='gem "historical_greeting", ">= 99"\n'
 if mode=='git':manifest+='git '+json.dumps(repo.as_uri())+', :branch => "main" do\n gem "git_leaf", "= 1.0.0"\nend\n'
 (project/'Gemfile').write_text(manifest)
 env={k:v for k,v in os.environ.items() if not k.startswith(('GEM_','RUBY','BUNDLE_','BUNDLER_PURIFIER_'))}
 env.update(HOME=str(work/(mode+'-home')),PATH=str(sdk/'bin')+':'+os.environ['PATH'],GEM_HOME=str(work/(mode+'-gems')),BUNDLE_PATH=str(project/'vendor/bundle'),BUNDLE_CACHE_PATH=str(project/'vendor/cache'),BUNDLER_PURIFIER_BUNDLER_VERSION='0.9.26',BUNDLER_PURIFIER_INPUT_VIEWS=json.dumps(views),BUNDLER_PURIFIER_PERSIST_LOCK='1')
 pathlib.Path(env['HOME']).mkdir()
 for command in ['install','lock']:run(mode+'-'+command,[sdk/'bin/ruby',root/'tools/native_bundle_command.rb',command],project,env)
 snapshot=json.loads(run(mode+'-snapshot',[sdk/'bin/ruby',root/'tools/native_lock_snapshot.rb'],project,env))
 assert snapshot['nativeHash']=='sha256-'+__import__('base64').b64encode(hashlib.sha256((project/'Gemfile.lock').read_bytes()).digest()).decode()
 assert snapshot['observed']['bundler']=='0.9.26'
 if mode=='git':
  nodes=snapshot['parsed']['gitSources'];assert len(nodes)==1 and nodes[0]['specs']==[dict(name='git_leaf',version='1.0.0')]
  assert nodes[0]['fields']['revision']==subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
 assert (project/'Gemfile').read_text()==manifest
 code='require "historical_greeting"; abort unless HistoricalGreeting.answer==42; '+('require "git_leaf"; abort unless GitLeaf.answer==17; ' if mode=='git' else '')+'puts "PASS"'
 assert run(mode+'-runtime',[sdk/'bin/ruby',root/'tools/native_bundle_command.rb','exec','ruby','-e',code],project,env).strip()=='PASS'
receipt['complete']=True;(work/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print('PASS native Git and implicit source snapshots and runtime')
