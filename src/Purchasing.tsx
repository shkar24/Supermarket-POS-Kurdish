import React, {useEffect,useState,useRef} from 'react';
import {supabase} from './supabase';

type Product={id:string;name:string};
type Draft={product_id:string;packs:string;pack_size:string;pack_price:string;discount:string;expires_on:string};
const blank=():Draft=>({product_id:'',packs:'1',pack_size:'1',pack_price:'',discount:'0',expires_on:''});
const number=(v:number)=>v.toLocaleString('en-US',{maximumFractionDigits:3});
const today=()=>new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Baghdad'}).format(new Date());
export default function Purchasing({products,refresh}:{products:Product[];refresh:()=>Promise<void>}){
 const [suppliers,setSuppliers]=useState<any[]>([]),[invoices,setInvoices]=useState<any[]>([]),[movements,setMoves]=useState<any[]>([]);
 const [name,setName]=useState(''),[phone,setPhone]=useState(''),[address,setAddress]=useState(''),[supplier,setSupplier]=useState('');
 const [invoice,setInvoice]=useState(''),[date,setDate]=useState(today),[paid,setPaid]=useState('0'),[lines,setLines]=useState<Draft[]>([blank()]);
 const [source,setSource]=useState('register');
 const funding=<label>سەرچاوەی پارە<select value={source} onChange={e=>setSource(e.target.value)}><option value="register">سندووقی مارکێت</option><option value="owner">پارەی خاوەن مارکێت</option></select></label>;
 const [selected,setSelected]=useState(''),[payment,setPayment]=useState(''),[detail,setDetail]=useState('');
 const [msg,setMsg]=useState(''),[busy,setBusy]=useState(false);const lock=useRef(false),requests=useRef(new Map<string,string>());
 async function reload(){
  if(!supabase)return;
  const result=await Promise.all([supabase.from('suppliers').select('id,name,phone').order('name'),supabase.from('purchases').select('id,invoice_number,invoice_date,total,suppliers(name),purchase_items(id,name_snapshot,quantity,net_amount,expires_on,remaining),supplier_payments(amount,created_at)').order('created_at',{ascending:false}),supabase.from('inventory_movements').select('id,created_at,reason,quantity_change,products(name)').order('created_at',{ascending:false}).limit(100)]);
  const issue=result.find(r=>r.error);if(issue?.error)throw new Error(issue.error.message);
  setSuppliers(result[0].data??[]);setInvoices(result[1].data??[]);setMoves(result[2].data??[]);
 }
 useEffect(()=>{void reload().catch(e=>setMsg(String(e)))},[]);
 function key(data:unknown){const k=JSON.stringify(data);if(!requests.current.has(k))requests.current.set(k,crypto.randomUUID());return requests.current.get(k)!}
 async function run(e:React.FormEvent,work:()=>Promise<void>){e.preventDefault();if(lock.current)return;lock.current=true;setBusy(true);setMsg('');try{await work();requests.current.clear();await Promise.all([reload(),refresh()]);setMsg('تۆمار کرا')}catch(e){setMsg(e instanceof Error?e.message:String(e))}finally{lock.current=false;setBusy(false)}}
 function field(i:number,k:keyof Draft,v:string){setLines(lines.map((l,j)=>i===j?{...l,[k]:v}:l))}
 const due=(i:any)=>Math.round((Number(i.total)-i.supplier_payments.reduce((s:number,p:any)=>s+Number(p.amount),0))*100)/100;
 const total=lines.reduce((s,l)=>s+Math.round((+l.packs*+l.pack_price-+l.discount)*100)/100,0);
 return <section dir="rtl">{msg&&<p role="status">{msg}</p>}
 <form className="manageform" onSubmit={e=>run(e,async()=>{const r=await supabase!.from('suppliers').insert({name:name.trim(),phone,address}).select('id').single();if(r.error)throw new Error(r.error.message);setSupplier(r.data.id);setName('');setPhone('');setAddress('')})}>
 <h3>دابینکەری نوێ</h3><input aria-label="ناوی دابینکەر" placeholder="ناوی مەندوب یان کۆمپانیا" value={name} onChange={e=>setName(e.target.value)} required/><input placeholder="مۆبایل" value={phone} onChange={e=>setPhone(e.target.value)}/><input placeholder="ناونیشان" value={address} onChange={e=>setAddress(e.target.value)}/><button disabled={busy}>زیادکردن</button></form>
 <form className="manageform" onSubmit={e=>run(e,async()=>{const args={p_supplier:supplier,p_invoice:invoice,p_date:date,p_items:lines.map(l=>({...l,packs:+l.packs,pack_size:+l.pack_size,pack_price:+l.pack_price,discount:+l.discount,expires_on:l.expires_on||null})),p_paid:+paid,p_source:source};const r=await supabase!.rpc('market_purchase',{...args,p_id:key(args)});if(r.error)throw new Error(r.error.message);setInvoice('');setPaid('0');setLines([blank()]);setDetail(r.data)})}>
 <h3>وەسڵی کڕین</h3><select required value={supplier} onChange={e=>setSupplier(e.target.value)}><option value="">دابینکەر هەڵبژێرە</option>{suppliers.map(s=><option key={s.id} value={s.id}>{s.name}</option>)}</select>
 <input required placeholder="ژمارەی وەسڵی مەندوب" value={invoice} onChange={e=>setInvoice(e.target.value)}/><label>بەرواری وەسڵ<input required type="date" value={date} onChange={e=>setDate(e.target.value)}/></label>
 {lines.map((l,i)=><fieldset key={i}><legend>کاڵای {i+1}</legend><select required value={l.product_id} onChange={e=>field(i,'product_id',e.target.value)}><option value="">کاڵا هەڵبژێرە</option>{products.map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select>
 {([['packs','ژمارەی پاکەت'],['pack_size','بڕ لە هەر پاکەت'],['pack_price','نرخی پاکەت'],['discount','داشکاندنی ئەم ڕیزە']] as const).map(([k,label])=><label key={k}>{label}<input required type="number" min={k==='packs'||k==='pack_size'?0.001:0} step={k==='packs'||k==='pack_size'?0.001:0.01} value={l[k]} onChange={e=>field(i,k,e.target.value)}/></label>)}
 <label>بەرواری بەسەرچوون<input type="date" value={l.expires_on} onChange={e=>field(i,'expires_on',e.target.value)}/></label>{lines.length>1&&<button type="button" onClick={()=>setLines(lines.filter((_,j)=>i!==j))}>لابردن</button>}</fieldset>)}
 <button type="button" onClick={()=>setLines([...lines,blank()])}>＋ ڕیزی کاڵا</button><label>پارەی دراو<input required type="number" min="0" max={total} step=".01" value={paid} onChange={e=>setPaid(e.target.value)}/></label>{funding}<b>کۆ {number(total)} د.ع · ماوە {number(total-Number(paid))} د.ع</b><button disabled={busy} className="primary">تۆمارکردنی وەسڵ و کۆگا</button></form>
 <form className="manageform" onSubmit={e=>run(e,async()=>{const args={p_purchase:selected,p_amount:+payment,p_source:source};const r=await supabase!.rpc('market_payment',{...args,p_id:key(args)});if(r.error)throw new Error(r.error.message);setSelected('');setPayment('')})}><h3>پارەدانی قەرزی مەندوب</h3><select required value={selected} onChange={e=>setSelected(e.target.value)}><option value="">وەسڵ هەڵبژێرە</option>{invoices.filter(i=>due(i)>0).map(i=><option value={i.id} key={i.id}>{i.suppliers.name} · {i.invoice_number} · {number(due(i))} د.ع</option>)}</select><input required placeholder="بڕی پارەدان" type="number" min=".01" step=".01" value={payment} onChange={e=>setPayment(e.target.value)}/>{funding}<button disabled={busy}>تۆمارکردنی پارەدان</button></form>
 <h3>وەسڵەکانی کڕین</h3><table><thead><tr><th>دابینکەر</th><th>وەسڵ</th><th>بەروار</th><th>کۆ</th><th>قەرز</th></tr></thead><tbody>{invoices.map(i=><tr key={i.id}><td>{i.suppliers.name}</td><td><button onClick={()=>setDetail(i.id===detail?'':i.id)}>{i.invoice_number}</button></td><td>{i.invoice_date}</td><td>{number(i.total)}</td><td>{number(due(i))}</td></tr>)}</tbody></table>
 {invoices.filter(i=>i.id===detail).map(i=><article className="manageform" key={i.id}><h3>{i.suppliers.name} · {i.invoice_number}</h3>{i.purchase_items.map((l:any)=><p key={l.id}>{l.name_snapshot} · {number(l.quantity)} · {number(l.net_amount)} د.ع · بەسەرچوون {l.expires_on??'—'}</p>)}{i.supplier_payments.map((p:any,j:number)=><p key={j}>پارەدان · {number(p.amount)} د.ع · {new Date(p.created_at).toLocaleDateString('en-GB',{timeZone:'Asia/Baghdad'})}</p>)}</article>)}
 <h3>دەفعە بەرواردارەکان</h3><table><tbody>{invoices.flatMap(i=>i.purchase_items).filter(l=>l.expires_on&&l.remaining>0).sort((a,b)=>a.expires_on.localeCompare(b.expires_on)).map(l=><tr key={l.id}><td>{l.name_snapshot}</td><td>{l.expires_on}</td><td>{number(l.remaining)}</td><td>{l.expires_on<today()?'بەسەرچووە':''}</td></tr>)}</tbody></table>
 <h3>دوایین جووڵەکانی کۆگا</h3><table><tbody>{movements.map(m=><tr key={m.id}><td>{m.products?.name}</td><td>{number(m.quantity_change)}</td><td>{({sale:'فرۆشتن',purchase:'کڕین',return:'گەڕاندنەوە',adjustment:'ڕاستکردنەوە'} as Record<string,string>)[m.reason]??m.reason}</td><td>{new Date(m.created_at).toLocaleString('en-GB',{timeZone:'Asia/Baghdad'})}</td></tr>)}</tbody></table></section>
}
