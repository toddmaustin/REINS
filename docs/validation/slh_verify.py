"""Small FIPS 205 SHA2-128s reference verifier for review fixtures, not production code."""
import hashlib,hmac

def address(layer,tree,typ,kp=0,x=0,y=0):
    return bytes([layer])+tree.to_bytes(8,'big')+bytes([typ])+kp.to_bytes(4,'big')+x.to_bytes(4,'big')+y.to_bytes(4,'big')

def digits(data,b,count):
    value=int.from_bytes(data,'big');bits=len(data)*8
    return [(value>>(bits-b*(i+1)))&((1<<b)-1) for i in range(count)]

class Verifier:
    def __init__(self):
        self.compressions=0
        self.chain_steps=0
        self.computed_root=None
        self.expected_root=None
    def sha(self,b):
        self.compressions+=(len(b)+9+63)//64
        return hashlib.sha256(b).digest()
    def verify(self,message,signature,public_key,context=b'',internal=False):
        if len(signature)!=7856 or len(public_key)!=32 or len(context)>255:return False
        seed,expected=public_key[:16],public_key[16:]
        m=message if internal else b'\0'+bytes([len(context)])+context+message
        prefix=hashlib.sha256(seed+bytes(48));self.compressions+=1
        def th(adr,b):
            h=prefix.copy();h.update(adr+b)
            self.compressions+=(len(adr)+len(b)+9+63)//64
            return h.digest()[:16]
        rnd=signature[:16]
        digest=self.sha(rnd+seed+self.sha(rnd+seed+expected+m)+(0).to_bytes(4,'big'))[:30]
        md=digest[:21];tree=int.from_bytes(digest[21:28],'big')&((1<<54)-1);leaf=int.from_bytes(digest[28:30],'big')&511
        indices=digits(md,12,14);pos=16;roots=[]
        for i,index in enumerate(indices):
            global_index=i*4096+index
            node=th(address(0,tree,3,leaf,0,global_index),signature[pos:pos+16]);pos+=16
            for j in range(12):
                sibling=signature[pos:pos+16];pos+=16
                pair=sibling+node if (index>>j)&1 else node+sibling
                global_index//=2
                node=th(address(0,tree,3,leaf,j+1,global_index),pair)
            roots.append(node)
        node=th(address(0,tree,4,leaf),b''.join(roots))
        for layer in range(7):
            coeff=digits(node,4,32);checksum=sum(15-x for x in coeff)<<4
            coeff+=digits(checksum.to_bytes(2,'big'),4,3)
            chains=[]
            for i,start in enumerate(coeff):
                val=signature[pos:pos+16];pos+=16
                self.chain_steps+=15-start
                for j in range(start,15):val=th(address(layer,tree,0,leaf,i,j),val)
                chains.append(val)
            node=th(address(layer,tree,1,leaf),b''.join(chains))
            for j in range(9):
                sibling=signature[pos:pos+16];pos+=16
                pair=sibling+node if (leaf>>j)&1 else node+sibling
                node=th(address(layer,tree,2,0,j+1,leaf>>(j+1)),pair)
            leaf=tree&511;tree>>=9
        assert pos==7856
        self.computed_root=node
        self.expected_root=expected
        return hmac.compare_digest(node,expected)

def verify(message,signature,public_key,context=b'',internal=False):
    return Verifier().verify(message,signature,public_key,context,internal)
