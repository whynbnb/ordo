//! 长任务（复制 / 移动 / 压缩 / 分析等）的进度与取消。
//!
//! 任务进度用通用单位表示（传输类为字节，分析类为条目数），`total` 为 0 时表示
//! 总量未知（界面显示不确定进度）。上层通过 `ordo_job_status` 轮询、`ordo_job_cancel`
//! 请求取消；执行方需周期性检查 [`Job::is_cancelled`]。

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Default)]
pub struct Job {
    progress: AtomicU64,
    total: AtomicU64,
    cancel: AtomicBool,
    done: AtomicBool,
}

impl Job {
    pub fn add(&self, units: u64) {
        self.progress.fetch_add(units, Ordering::Relaxed);
    }

    pub fn set_total(&self, total: u64) {
        self.total.store(total, Ordering::Relaxed);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    pub fn complete(&self) {
        self.done.store(true, Ordering::Relaxed);
    }
}

static JOBS: OnceLock<Mutex<HashMap<u64, Arc<Job>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);

fn jobs() -> &'static Mutex<HashMap<u64, Arc<Job>>> {
    JOBS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn create() -> (u64, Arc<Job>) {
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let job = Arc::new(Job::default());
    if let Ok(mut guard) = jobs().lock() {
        guard.insert(id, job.clone());
    }
    (id, job)
}

pub fn get(id: u64) -> Option<Arc<Job>> {
    jobs().lock().ok()?.get(&id).cloned()
}

pub fn snapshot(id: u64) -> Value {
    match get(id) {
        Some(job) => json!({
            "progress": job.progress.load(Ordering::Relaxed),
            "total": job.total.load(Ordering::Relaxed),
            "cancelled": job.cancel.load(Ordering::Relaxed),
            "done": job.done.load(Ordering::Relaxed),
        }),
        None => json!({
            "progress": 0,
            "total": 0,
            "cancelled": false,
            "done": true,
        }),
    }
}

pub fn cancel(id: u64) {
    if let Some(job) = get(id) {
        job.cancel();
    }
}

pub fn cleanup(id: u64) {
    if let Ok(mut guard) = jobs().lock() {
        guard.remove(&id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_cancel_and_cleanup() {
        let (id, job) = create();
        job.set_total(1000);
        job.add(250);
        let snap = snapshot(id);
        assert_eq!(snap["progress"], 250);
        assert_eq!(snap["total"], 1000);
        assert_eq!(snap["cancelled"], false);

        cancel(id);
        assert!(job.is_cancelled());
        assert_eq!(snapshot(id)["cancelled"], true);

        job.complete();
        assert_eq!(snapshot(id)["done"], true);

        cleanup(id);
        // 清理后按未知任务处理。
        assert_eq!(snapshot(id)["total"], 0);
    }
}
