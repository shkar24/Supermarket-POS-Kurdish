import {useEffect,useRef,useState} from 'react';
import {Pencil, Plus, Trash2, X} from 'lucide-react';
import {supabase} from './supabase';

type Kind='sale'|'purchase';
type Line={id:string;name:string;units:number;size:number;price:number;discount:number};
type Payment={id:string;amount:number;source:string|null;date?:string};
type Receipt={number:string;total:number;discount:number;lines:Line[];payments:Payment[]};
type Props={kind:Kind;id:string;close:()=>void;saved:()=>Promise<void>};
const money=(v:number)=>v.toLocaleString('en-US',{maximumFractionDigits:2})+' د.ع';
const round=(v:number)=>Math.round((v+Number.EPSILON)*100)/100;

export default function ReceiptEditor({kind,id,close,saved}:Props){
 const dialog=useRef<HTMLDialogElement>(null),lock=useRef(false),request=useRef(crypto.randomUUID());
 const [original,setOriginal]=useState<Receipt|null>(null),[lines,setLines]=useState<Line[]>([]),[payments,setPayments]=useState<Payment[]>([]),[discount,setDiscount]=useState(0);
 const [reason,setReason]=useState(''),[error,setError]=useState(''),[busy,setBusy]=useState(false);
 const purchase=kind==='purchase';
 useEffect(()=>{
  let active=true;dialog.current?.showModal();
  void supabase?.rpc('receipt_edit_data',{p_kind:kind,p_id:id}).then(({data,error})=>{
   if(!active)return;
   if(error){setError(error.message);return}
   const receipt=data as Receipt;setOriginal(receipt);setLines(receipt.lines);setPayments(receipt.payments);setDiscount(receipt.discount);
  });
  return()=>{active=false};
 },[kind,id]);
 function changeLine(index:number,field:keyof Pick<Line,'units'|'size'|'price'|'discount'>,value:number){
  setLines(items=>items.map((line,i)=>i===index?{...line,[field]:value}:line));
 }
 const total=round(lines.reduce((sum,line)=>sum+round(line.units*line.price)-line.discount,0)-discount);
 const paid=round(payments.reduce((sum,p)=>sum+p.amount,0));
 const changed=original&&(JSON.stringify(lines)!==JSON.stringify(original.lines)||JSON.stringify(payments)!==JSON.stringify(original.payments)||discount!==original.discount);
 async function submit(event:React.FormEvent){
  event.preventDefault();if(!supabase||!original||lock.current||!changed)return;
  lock.current=true;setBusy(true);setError('');
  try{
   const {error}=await supabase.rpc('edit_receipt',{p_kind:kind,p_id:id,p_before:original,p_lines:lines,p_discount:discount,p_payments:payments,p_reason:reason.trim(),p_request:request.current});
   if(error)throw new Error(error.message);
   await saved();close();
  }catch(e){setError(e instanceof Error?e.message:String(e))}
  finally{lock.current=false;setBusy(false)}
 }
 return <dialog className="receipt-editor" dir="rtl" ref={dialog} onCancel={e=>{e.preventDefault();if(!lock.current)close()}}>
 <header><h2><Pencil/>{purchase?'دەستکاریی وەسڵی کڕین':'دەستکاریی وەسڵی فرۆشتن'}</h2><button type="button" disabled={busy} aria-label="داخستن" onClick={close}><X/></button></header>
 {error&&<p className="error" role="alert">{error}</p>}
 {!original&&!error&&<p>وەسڵەکە دەهێنرێت…</p>}
 {original&&<form onSubmit={submit}><p><bdi>{original.number}</bdi> · کۆی پێشوو {money(original.total)}</p>
 {lines.map((line,i)=><fieldset key={line.id}><legend>{line.name}</legend>
 <label>{purchase?'ژمارەی پاکەت':'ژمارە / بڕ'}<input type="number" required min=".001" step=".001" value={line.units||''} onChange={e=>changeLine(i,'units',Number(e.target.value))}/></label>
 {purchase&&<label>بڕ لە هەر پاکەت<input type="number" required min=".001" step=".001" value={line.size||''} onChange={e=>changeLine(i,'size',Number(e.target.value))}/></label>}
 <label>{purchase?'نرخی پاکەت':'نرخی یەکە'}<input type="number" required min="0" step=".01" value={line.price} onChange={e=>changeLine(i,'price',Number(e.target.value))}/></label>
 {purchase&&<label>داشکاندنی ڕیز<input type="number" required min="0" step=".01" value={line.discount} onChange={e=>changeLine(i,'discount',Number(e.target.value))}/></label>}
 <small>کۆی ڕیز {money(round(line.units*line.price)-line.discount)}</small></fieldset>)}
 {!purchase&&<label>داشکاندنی وەسڵ<input type="number" min="0" step=".01" required value={discount} onChange={e=>setDiscount(Number(e.target.value))}/></label>}
 {purchase&&<><h3>پارەدانەکان</h3>{payments.map((p,i)=><fieldset key={p.id}><legend>{p.date?new Date(p.date).toLocaleDateString('en-GB',{timeZone:'Asia/Baghdad'}):'پارەدانی نوێ'}</legend><label>بڕی پارەدان<input required type="number" min=".01" step=".01" value={p.amount||''} onChange={e=>setPayments(old=>old.map((x,j)=>j===i?{...x,amount:Number(e.target.value)}:x))}/></label>
 <label>سەرچاوە<select value={p.source??''} onChange={e=>setPayments(old=>old.map((x,j)=>j===i?{...x,source:e.target.value}:x))}>{!p.source&&<option value="">نادیار</option>}<option value="register">سندووقی مارکێت</option><option value="owner">خاوەن مارکێت</option></select></label>
 <button type="button" onClick={()=>setPayments(old=>old.filter(x=>x.id!==p.id))}><Trash2/>لابردنی ئەم پارەدانە</button></fieldset>)}
 <button type="button" onClick={()=>setPayments(old=>[...old,{id:crypto.randomUUID(),amount:0,source:'register'}])}><Plus/>زیادکردنی پارەدان</button></>}
 <div className="stats"><div><small>کۆی نوێ</small><strong>{money(total)}</strong></div>{purchase&&<><div><small>پارەی دراو</small><strong>{money(paid)}</strong></div><div><small>قەرزی ماوە</small><strong>{money(round(total-paid))}</strong></div></>}</div>
 <label>هۆکاری دەستکاری<input required maxLength={500} value={reason} onChange={e=>setReason(e.target.value)}/></label>
 <button className="primary" disabled={busy||!changed||!reason.trim()||total<0||(purchase&&paid>total)}>{busy?'پاشەکەوت دەکرێت…':'پاشەکەوتکردنی دەستکارییەکان'}</button></form>}
 </dialog>
}
