import {useEffect,useState} from 'react';
import {supabase} from './supabase';

export default function DebtorPicker({value,onChange}:{value:string;onChange:(name:string)=>void}){
 const [names,setNames]=useState<{id:string;name:string}[]>([]);
 const [mode,setMode]=useState<'saved'|'new'>(value?'new':'saved');
 const [error,setError]=useState(''),[loading,setLoading]=useState(true);
 useEffect(()=>{
  let active=true;
  async function load(){
   if(!supabase)return;
   const all:{id:string;name:string}[]=[];
   for(let offset=0;;offset+=500){
    const result=await supabase.from('credit_customers').select('id,name').order('name').order('id').range(offset,offset+499);
    if(!active)return;
    if(result.error){setError(result.error.message);setLoading(false);return}
    all.push(...result.data);
    if(result.data.length<500)break;
   }
   setNames(all);if(!all.length)setMode('new');setLoading(false);
  }
  void load();return()=>{active=false};
 },[]);
 return <><label>قەرزدار<select disabled={loading} value={mode==='new'?'new':names.find(n=>n.name===value)?.id??''} onChange={e=>{
   if(e.target.value==='new'){setMode('new');onChange('');return}
   setMode('saved');onChange(names.find(n=>n.id===e.target.value)?.name??'');
 }}><option value="">{loading?'ناوەکان دەهێنرێن…':'قەرزدارێک هەڵبژێرە'}</option>{names.map(n=><option key={n.id} value={n.id}>{n.name}</option>)}<option value="new">＋ قەرزداری نوێ</option></select></label>
 {mode==='new'&&<label>ناوی قەرزداری نوێ<input maxLength={160} value={value} onChange={e=>onChange(e.target.value)}/></label>}{error&&<p className="error">{error}</p>}</>
}