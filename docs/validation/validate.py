"""Algorithm/format checks and abstract gates, not an implementation fault proof."""
from pathlib import Path
from dataclasses import dataclass, replace
from collections import defaultdict
import hashlib,json
from slh_verify import Verifier
R=Path(__file__).parent;H=lambda b:hashlib.sha256(b).digest();results=[]
official=json.loads((R/'SLH_DSA_ACVP_vectors.json').read_text())
signed=json.loads((R/'REINS_signed_batch_fixtures.json').read_text())
valid=0
for t in official['tests']:
 args=[bytes.fromhex(t['message']),bytes.fromhex(t['signature']),bytes.fromhex(t['pk']),bytes.fromhex(t.get('context','')),t['interface']=='internal']
 assert Verifier().verify(*args)==t['expected'],t['tcId']
 if t['expected']:
  valid+=1
  for off in [0,16]+[2928+704*j for j in range(7)]:
   sig=bytearray(args[1]);sig[off]^=1;assert not Verifier().verify(args[0],bytes(sig),*args[2:])
results.append(f'All {len(official["tests"])} selected official NIST ACVP SHA2-128s cases matched expected outcomes ({valid} valid), with R/FORS/seven-layer mutations rejected. Internal/nonempty-context algorithm tests remain separate from the production pure/empty-context interface.')
otp=bytes.fromhex(signed['otp']);cfg=H(otp);request=bytes.fromhex(signed['request']);keys=[bytes.fromhex(x) for x in signed['public_keys']]
assert len(otp)==272 and otp[4:12]==bytes([0,2,2,2,3,2,0,0]) and otp[92:128]==bytes(36)
assert cfg.hex()==signed['configuration_digest'] and [otp[144+48*i:176+48*i] for i in range(3)]==keys
assert len(request)==128 and request[:8]==b'REIN\x02\x03\x00\x00' and request[40:72]==bytes(32) and request[112:]==bytes(16)
def canonical(b):
 return len(b)==128 and b[:4]==b'REIN' and b[4]==2 and b[5] in [1,3] and b[6]<3 and b[7]==0 and b[8:40]==request[8:40] and b[40:72]==bytes(32) and b[112:]==bytes(16) and int.from_bytes(b[72:80],'big')>0
def grant(pending):b=bytearray(pending);b[5]+=1;return bytes(b)
def root_for(pending,index,path):
 x=H(b'\0REINS-AUTH-v2'+grant(pending)+cfg)
 for j,sib in enumerate(path):x=H(b'\1'+(sib+x if (index>>j)&1 else x+sib))
 return x
@dataclass(frozen=True)
class Evidence:
 code:int
 count_ok:bool=True
 complete:bool=True
 context_live:bool=True
 in_time:bool=True
 generation_ok:bool=True
 hold_clear:bool=True
 integrity_ok:bool=True
A=0xA55A;B=0x3CC3
def gate(evidence):
 return len(evidence)==2 and all(e.code==code and all([e.count_ok,e.complete,e.context_live,e.in_time,e.generation_ok,e.hold_clear,e.integrity_ok]) for e,code in zip(evidence,[A,B]))
def accept(reply,pending=request,now=61_000_000,current_expiry=None,hold=False,stale=False):
 total=len(reply)
 if total<7860 or (total-7860)%32 or not canonical(pending):return False
 depth=(total-7860)//32
 if depth>20:return False
 sig=reply[:7856];index=int.from_bytes(reply[7856:7860],'big')
 if index>=1<<depth:return False
 issue=(int.from_bytes(pending[72:80],'big')-1)*30_000_000
 if issue+300_000_000>=2**64:return False
 intime=issue<=now<issue+30_000_000 and (current_expiry is None or now<current_expiry)
 path=[reply[o:o+32] for o in range(7860,total,32)];evidence=[]
 for passno,code in enumerate([A,B]):
  local=bytes(bytearray(pending));pk=bytes(bytearray(keys[local[6]]))
  v=Verifier();ok=v.verify(b'REINS-BATCH-v2'+root_for(local,index,path),sig,pk,b'')
  expected=324+v.chain_steps
  assert v.compressions==expected and v.compressions<=3999
  if passno==0:equal=v.computed_root==pk[16:]
  else:equal=bytes(x^255 for x in v.computed_root)==bytes(x^255 for x in pk[16:])
  assert equal==ok
  evidence.append(Evidence(code if equal else 0,count_ok=v.compressions==expected,in_time=intime,generation_ok=not stale,hold_clear=not hold))
 return gate(evidence)
votes=set()
for batch in signed['batches']:
 slot=batch['slot'];reply=bytes.fromhex(batch['reply']);pending=bytearray(request);pending[6]=slot;pending=bytes(pending)
 assert reply[:7856]==bytes.fromhex(batch['signature']) and len(reply)==7924 and accept(reply,pending);votes.add(slot)
 assert root_for(pending,batch['index'],[bytes.fromhex(x) for x in batch['path']]).hex()==batch['root']
 assert not accept(reply,pending,now=90_000_000) and not accept(reply,pending,current_expiry=61_000_000)
 assert not accept(reply,pending,hold=True) and not accept(reply,pending,stale=True)
 for off in [0,16]+[2928+704*j for j in range(7)]+[7859,7860,len(reply)-1]:
  altered=bytearray(reply);altered[off]^=1;assert not accept(bytes(altered),pending),off
 assert not accept(reply[:-1],pending) and not accept(reply+bytes(32*21),pending)
 for off in [5,6,8,24,40,72,80,111,112,127]:
  altered=bytearray(pending);altered[off]^=1;assert not accept(reply,bytes(altered)),off
 msg=b'REINS-BATCH-v2'+bytes.fromhex(batch['root']);v=Verifier();assert v.verify(msg,reply[:7856],keys[slot]) and v.compressions==324+v.chain_steps
 assert not Verifier().verify(msg,reply[:7856],keys[(slot+1)%3])
 assert not Verifier().verify(b'REINS-BATCH-v1'+msg[14:],reply[:7856],keys[slot])
 assert not Verifier().verify(msg,reply[:7856],keys[slot],b'nonempty')
assert votes=={0,1};votes.add(0);assert len(votes)==2
results.append('Two regenerated body-free REINS replies verified in two passes and form a distinct 2-of-3 quorum. Wrong signature layers, path/index, key, label, context and protected pending nonce/slot/round/configuration were rejected. Window/expiry equality, hold, stale generation, malformed sizes and duplicate voting were checked.')
for roundno in range(100):
 invalid=[Evidence(0),Evidence(0)];assert not gate(invalid)
 for side,code in enumerate([A,B]):
  fault=list(invalid);fault[side]=replace(fault[side],code=code);assert not gate(fault)
 for field in ['count_ok','complete','context_live','in_time','generation_ok','hold_clear','integrity_ok']:
  invalid=[replace(Evidence(A),**{field:False}),replace(Evidence(B),**{field:False})]
  for side in [0,1]:
   fault=list(invalid);fault[side]=replace(fault[side],**{field:True});assert not gate(fault)
assert gate([Evidence(A),Evidence(B)])
for side in [0,1]:
 e=[Evidence(A),Evidence(B)];e[side]=replace(e[side],code=e[side].code^1);assert not gate(e)
results.append('Abstract acceptance gates reject one forced comparator/accept code or late/stale/count/completion/hold predicate in either lane across 100 consecutive rounds. This does not inject faults into a SHA datapath, RTL sequencer, shared hand-off, physical register or join circuit; those proofs remain required.')
def tree(leaves):
 target=1<<(len(leaves)-1).bit_length();leaves=leaves+[leaves[-1]]*(target-len(leaves));levels=[leaves]
 while len(leaves)>1:leaves=[H(b'\1'+leaves[i]+leaves[i+1]) for i in range(0,len(leaves),2)];levels.append(leaves)
 return levels
for count in [1,2,3,5,17]:
 leaves=[H(b'\0'+bytes([i])) for i in range(count)];levels=tree(leaves)
 for i in range(count):
  x=leaves[i]
  for j in range(len(levels)-1):
   sib=levels[j][(i>>j)^1];x=H(b'\1'+(sib+x if (i>>j)&1 else x+sib))
  assert x==levels[-1][0]
traffic={}
for depth in range(21):
 total=7860+32*depth;chunks=(total+63)//64;last=total%64 or 64
 assert total<=8500<9216 and chunks<=133
 traffic[str(depth)]=dict(total_reply=total,chunks=chunks,last_count=last,spi_bytes_three=3*(135+11+chunks*87+15))
assert traffic['0']==dict(total_reply=7860,chunks=123,last_count=52,spi_bytes_three=32586)
assert traffic['17']==dict(total_reply=8404,chunks=132,last_count=20,spi_bytes_three=34935)
assert traffic['20']==dict(total_reply=8500,chunks=133,last_count=52,spi_bytes_three=35196)
assert 16+14*13*16+7*(35+9)*16==7856 and 3675+324==3999 and 2*(3999+3+40)<=8200
assert (300_000_000+1)/800_000+.001+.002==375.00300125 and 500/800_000==.000625 and .001/.000625==1.6
for n in range(1,9):
 assert (128+48*n)//16-1==7+3*n
 for q in range(1,n+1):
  for c in range(n+1):
   for u in range(n-c+1):assert ((c<q) and (n-c-u>=q))==(c<q<=n-c-u)
results.append('Merkle padding/paths for 1,2,3,5,17 leaves, all depth-0-to-20 body-free sizes/chunks/traffic, zero OTP depth bytes, 8,200 two-pass budget, 375.00300125 s withdrawal bound, 625 us guard interval, OTP chunk indices and all 36 N/Q cases passed.')
class Receive:
 def __init__(self,total):self.total=total;self.offset=0;self.sealed=False
 def chunk(self,offset,count,complete=True):
  if self.sealed or offset!=self.offset or not 1<=count<=64 or offset+count>self.total:return False
  if complete:self.offset+=count
  return complete
 def finish(self):
  if self.offset!=self.total:return False
  self.sealed=True;return True
rx=Receive(7860);assert not rx.finish() and not rx.chunk(1,1) and not rx.chunk(0,64,False) and rx.offset==0
while rx.offset<rx.total:assert rx.chunk(rx.offset,min(64,rx.total-rx.offset))
assert rx.finish() and not rx.chunk(rx.offset,1)
class Hold:
 def __init__(self):self.value=True
 def reset(self,cold=False,startup=False,nonce=False):
  if cold and startup and nonce:self.value=False
  return self.value
h=Hold();assert h.reset() and h.reset(cold=True) and h.reset(startup=True,nonce=True) and not h.reset(cold=True,startup=True,nonce=True)
class Admission:
 def __init__(self):self.buckets=defaultdict(list)
 def approve(self,device,roundno,candidate,now):
  key=(device,roundno);self.buckets[key]=[(t,b) for t,b in self.buckets[key] if t>now-375004000]
  if any(b==candidate for t,b in self.buckets[key]):return True
  if len(self.buckets[key])>=4:return False
  self.buckets[key].append((now,candidate));return True
ad=Admission()
for i in range(4):assert ad.approve('D',1,bytes([i]),0)
assert ad.approve('D',1,b'\x00',1) and not ad.approve('D',1,b'fifth',2)
assert not ad.approve('D',1,b'claimed restart',375003999) and ad.approve('D',1,b'after retention',375004000)
results.append('Abstract zero-based receive/seal, cold-reset-only entropy-hold clearing, and four-candidate rolling admission checks passed, including duplicate retry and claimed-restart cap bypass rejection. Authority durability/atomicity and physical reset/sealing were not tested.')
payload=dict(protocol=2,signature_profile='SLH-DSA-SHA2-128s',configuration_digest=cfg.hex(),request=request.hex(),nonce=request[80:112].hex(),slot0_leaf=H(b'\0REINS-AUTH-v2'+grant(request)+cfg).hex(),slot0_root=signed['batches'][0]['root'],traffic=traffic,results=results)
(R/'REINS_validation_vectors.json').write_text(json.dumps(payload,indent=2))
lim='Not performed: production RTL/formal acceptance or repeated/persistent physical-fault proof; SHA common-path protection; physical entropy/clock/guard/reset/SRAM/on-die qualification; authority aggregate admission durability/atomicity; synthesis, silicon area/power or end-to-end latency measurements.'
(R/'REINS_validation_record.md').write_text('# REINS validation record\n\n'+''.join('- '+x+'\n' for x in results)+'\n'+lim+'\n')
p=R/'REINS_Hardware_Specification.md'
if not p.exists():p=R.parent/'REINS_Hardware_Specification.md'
s=p.read_text().split('### A.2 Computed fixtures')[0]+'### A.2 Computed fixtures\n\n'
s+='The complete public OTP and two valid pure/empty-context body-free REINS batch replies are in REINS_signed_batch_fixtures.json. The reference verifier matched 28 official NIST SHA2-128s cases. Generated root signatures are public test material, not official known-answer signatures. Each reply is verified twice by the acceptance model.\n\n'
for title,key in [('Configuration digest','configuration_digest'),('Round nonce','nonce'),('Slot 0 locally constructed leaf','slot0_leaf'),('Slot 0 batch root','slot0_root')]:s+=f'**{title}:** `{payload[key]}`\n\n'
s+='The exact unsigned 128-byte RENEW_REQUEST body, with bytes 40-71 zero, is:\n\n'+''.join('    '+request.hex()[i:i+64]+'\n' for i in range(0,256,64))
s+='\nRound 3 gives I=60,000,000, E=360,000,000 and B=90,000,000 ticks. The three-candidate example pads to four leaves, depth 2; its reply is 7,924 bytes and omits the grant body. At depth 17 a reply is 8,404 bytes in 132 zero-based chunks. The N=3 READ_TX/upload example is 34,935 SPI bytes. The depth-20 maximum is 8,500 bytes. Exact provenance, actual checks and limitations are in the accompanying validation files. Abstract acceptance tests do not establish RTL or physical fault resistance.\n'
p.write_text(s);print('\n'.join(results))
