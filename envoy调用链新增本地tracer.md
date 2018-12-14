# 1 原生支持的tracer #
```
class TracerNameValues {
public:
  // Lightstep tracer
  const std::string LIGHTSTEP = "envoy.lightstep";

  // Zipkin tracer
  const std::string ZIPKIN = "envoy.zipkin";

  // Dynamic tracer
  const std::string DYNAMIC_OT = "envoy.dynamic.ot";
};
```

# 2 本地调用日志需求 #
为了防止同步上报影响主题功能，同时也为了防止出现调用链在网络拥堵时出现丢失，需要增加一个本地tracer，按格式打印到本地，再通过filebeat采集存储
格式如下：
```
{
    "traceId":"e4531568dabb29ec",
    "name":"http:/sayhi",
    "id":"e4531568dabb29ec",
    "kind":"CLIENT",
    "timestamp":1541629187466843,
    "duration":3989,
    "localEndpoint":{
        "ipv4":"9.77.7.35",
        "port":0,
        "serviceName":"reporttimeb"
    },
    "remoteEndpoint":{
        "ipv4":"9.77.7.132",
        "port":8080,
        "serviceName":"reporttimeb"
    },
    "tags":{
        "remoteInterface":"reporttimeb.",
        "resultStatus":"success",
        "http.method":"GET",
        "url":"http://reporttimeb/",
        "requestId":"a35a9136-14ab-9995-8cc7-221629af0f27"
    }
}

{
    "traceId":"7ac78718eb1d0d92",
    "name":"http:/sayhi",
    "id":"7ac78718eb1d0d92",
    "kind":"SERVER",
    "timestamp":1541572126013695,
    "duration":1060,
    "localEndpoint":{
        "ipv4":"",
        "port":0,
        "serviceName":"9.77.7.35"
    },
    "remoteEndpoint":{
        "ipv4":"9.77.6.128",
        "port":0
    },
    "tags":{
        "localInterface":"9.77.7.35:8080.sayhi",
        "resultStatus":"success",
        "http.method":"GET",
        "requestId":"0334c2ae-f415-9014-b6eb-f028b1837009"
    }
}
```

# 3 新增tracer: local #
因为需求的格式基本跟zipkin上报的格式一致，所以通过改造原生zipkin driver来实现一个local driver
1 新增envoy.local
well_known_names.h
```
class TracerNameValues {
public:
  // Lightstep tracer
  const std::string Lightstep = "envoy.lightstep";
  // Zipkin tracer
  const std::string Zipkin = "envoy.zipkin";
  // Dynamic tracer
  const std::string DynamicOt = "envoy.dynamic.ot";
  // Local tracer
  const std::string Local = "envoy.local";
};
```
2 新增local::Driver
local_tracer_impl.cc
```
Driver::Driver(...)
    : log_(log), tracer_stats_{ZIPKIN_TRACER_STATS(
                                POOL_COUNTER_PREFIX(stats, "tracing.local."))},
      tls_(tls.allocateSlot()), runtime_(runtime), local_info_(local_info) {

  const std::string collector_endpoint =
      config.getString("collector_endpoint", ZipkinCoreConstants::get().DEFAULT_COLLECTOR_ENDPOINT);

  const bool trace_id_128bit =
      config.getBoolean("trace_id_128bit", ZipkinCoreConstants::get().DEFAULT_TRACE_ID_128BIT);

  tls_->set([this, collector_endpoint, &random_generator, trace_id_128bit](
                Event::Dispatcher& dispatcher) -> ThreadLocal::ThreadLocalObjectSharedPtr {
    TracerPtr tracer(new Tracer(local_info_.clusterName(), local_info_.address(), random_generator,
                                trace_id_128bit));
    tracer->setReporter(
        ReporterImpl::NewInstance(std::ref(*this), std::ref(dispatcher), collector_endpoint));
    return ThreadLocal::ThreadLocalObjectSharedPtr{new TlsTracer(std::move(tracer), *this)};
  });
}
```
3 新增local:：Reporter
local_tracer_impl.cc
```
ReporterImpl::ReporterImpl(Driver& driver, Event::Dispatcher& dispatcher,
                           const std::string& collector_endpoint)
    : driver_(driver), collector_endpoint_(collector_endpoint) {
  file_ = driver_.logManager().createAccessLog(collector_endpoint_);

  flush_timer_ = dispatcher.createTimer([this]() -> void {
    driver_.tracerStats().timer_flushed_.inc();
    flushSpans();
    enableTimer();
  });

  const uint64_t min_flush_spans =
      driver_.runtime().snapshot().getInteger("tracing.zipkin.min_flush_spans", 5U);
  span_buffer_.allocateBuffer(min_flush_spans);

  enableTimer();
}

//刷到文件
void ReporterImpl::flushSpans() {
  if (span_buffer_.pendingSpans()) {
    driver_.tracerStats().spans_sent_.add(span_buffer_.pendingSpans());

    const std::string request_body = span_buffer_.toStringifiedJsonArray();
    file_->write(request_body);
    span_buffer_.clear();
  }
}
```
4 增加local driver的json schema
config_schemas.cc
```
  "local_driver" : {
    "type" : "object",
    "properties" : {
      "type" : {
        "type" : "string",
        "enum" : ["local"]
      },
      "config" : {
        "type" : "object",
        "properties" : {
          "collector_cluster" : {"type" : "string"},
          "collector_endpoint": {"type": "string"}
        },
        "required": ["collector_cluster", "collector_endpoint"],
        "additionalProperties" : false
      }
    },
    "required" : ["type", "config"],
    "additionalProperties" : false
  }
```
5 配置Local::Driver
bootstrap配置文件中
```
tracing:
  http:
    config:
      collector_cluster: local
      collector_endpoint: /data/tsf_apm/trace/logs/trace_log.log
    name: envoy.local
```