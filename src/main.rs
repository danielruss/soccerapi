use std::time::Instant;

use axum::{
    Json, Router,
    extract::Query,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use soccer_rs::{
    JobDescription, MyError, SOCcerResult, get_crosswalk, run_clips_job, run_soccer_job,
};
use serde::{Deserialize, Serialize};

pub struct AppError(pub MyError);
impl From<MyError> for AppError {
    fn from(value: MyError) -> Self {
        AppError(value)
    }
}
impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        // You can customize this! For now, let's make everything a 500 error.
        (StatusCode::INTERNAL_SERVER_ERROR, self.0.to_string()).into_response()
    }
}

#[tokio::main]
async fn main() {
    let start = Instant::now();

    let app = Router::new()
        .route("/", get(root))
        .route("/soccer", get(soccer))
        .route("/soccernet", get(soccer))
        .route("/clips", get(clips));

    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".to_string());
    let address = format!("0.0.0.0:{}", port);
    let listener = tokio::net::TcpListener::bind(&address).await.unwrap();

    let duration = start.elapsed();
    println!("🚀 Axum started in: {:?}", duration);

    axum::serve(listener, app).await.unwrap();
}

#[derive(Debug, Serialize)]
struct Heartbeat {
    status: &'static str,
}
impl Default for Heartbeat {
    fn default() -> Self {
        Self { status: "Alive" }
    }
}

async fn root() -> Json<Heartbeat> {
    let response = Heartbeat::default();
    Json(response)
}

fn update_prior(from_sys: &str, to_sys: &str, codes: Option<String>, prior: &mut Vec<u16>) {
    if let Some(codes_string) = codes {
        let code_vec: Vec<&str> = codes_string.split(",").map(|s| s.trim()).collect();
        let Ok(crosswalk) = get_crosswalk(from_sys, to_sys) else {
            return;
        };
        crosswalk.crosswalk_into(&code_vec, prior);
    }
}

fn default_n() -> usize {
    10
}

#[derive(Deserialize)]
pub struct SoccerParams {
    #[serde(rename = "JobTitle")]
    job_title: String,
    #[serde(rename = "JobTask", alias = "JobTasks")]
    job_task: Option<String>,
    soc1980: Option<String>,
    noc2011: Option<String>,
    isco1988: Option<String>,
    version: Option<String>,
    #[serde(default = "default_n")]
    n: usize,
}

async fn soccer(Query(params): Query<SoccerParams>) -> Result<Json<Vec<SOCcerResult>>, AppError> {
    let version = params.version.unwrap_or("1.0.0".to_string());
    let n = params.n;

    let mut prior: Vec<u16> = Vec::new();
    update_prior("soc1980", "soc2010", params.soc1980, &mut prior);
    update_prior("noc2011", "soc2010", params.noc2011, &mut prior);
    update_prior("isco1988", "soc2010", params.isco1988, &mut prior);
    let multihot_prior = prior.into_boxed_slice();

    let job = JobDescription {
        id: "soccer-job".to_string(),
        text1: params.job_title,
        text2: params.job_task,
        multihot_prior,
    };

    let results = run_soccer_job(&job, &version, n)?.into_iter().collect();
    Ok(Json(results))
}

#[derive(Deserialize)]
pub struct ClipsParams {
    products_services: String,
    sic1987: Option<String>,
    version: Option<String>,
    #[serde(default = "default_n")]
    n: usize,
}
async fn clips(Query(params): Query<ClipsParams>) -> Result<Json<Box<[SOCcerResult]>>, AppError> {
    let version = params.version.unwrap_or("1.0.0".to_string());
    let n = params.n;

    let mut prior: Vec<u16> = Vec::new();
    update_prior("sic1987", "naics2022", params.sic1987, &mut prior);
    let multihot_prior = prior.into_boxed_slice();

    let job = JobDescription {
        id: "clips-job".to_string(),
        text1: params.products_services,
        text2: None,
        multihot_prior,
    };

    let results = run_clips_job(&job, &version, n)?;
    Ok(Json(results))
}
