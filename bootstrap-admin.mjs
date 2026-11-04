import { createClient } from '@supabase/supabase-js';
const url=process.env.SUPABASE_URL;
const serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
const password=process.env.RULZZ_ADMIN_PASSWORD;
if(!url||!serviceKey||!password){console.error('Set SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, and RULZZ_ADMIN_PASSWORD.');process.exit(1)}
if(password.length<14){console.error('Choose a unique admin password with at least 14 characters; do not use the temporary chat password.');process.exit(1)}
const supabase=createClient(url,serviceKey,{auth:{autoRefreshToken:false,persistSession:false}});
const email='rulzzadmin@rulzzgtps.id';
const {data,error}=await supabase.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{username:'RulzzAdmin'}});
let user=data?.user;
if(error && !/already registered|already been registered/i.test(error.message)){console.error(error.message);process.exit(1)}
if(!user){const {data:list,error:listError}=await supabase.auth.admin.listUsers({page:1,perPage:1000});if(listError)throw listError;user=list.users.find(x=>x.email===email);if(!user)throw new Error('Existing admin user could not be located');const {error:updateError}=await supabase.auth.admin.updateUserById(user.id,{password});if(updateError)throw updateError;}
const {error:roleError}=await supabase.from('admin_users').upsert({user_id:user.id,username:'RulzzAdmin'});
if(roleError)throw roleError;
console.log('Admin account provisioned. Username: RulzzAdmin. Email login is mapped internally.');
