module time

#var $timeOff = 0;
#var $seen = 0
#function $sys_mono_new_Date() {
#var t = Date.now()
#if (t < seen)
#timeOff += (seen - t)
#
#seen = t
#return t + timeOff
#}

pub fn sys_mono_now() u64 {
	$if js_browser {
		mut res := u64(0)
		#res = new u64(window.performance.now() * 1000000)

		return res
	} $else $if js_node {
		mut res := u64(0)
		#res.val = Number($process.hrtime.bigint())

		return res
	} $else {
		mut res := u64(0)
		#res = new u64($sys_mono_new_Date() * 1000000)

		return res
	}
}
