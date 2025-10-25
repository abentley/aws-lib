local tf = import 'tf.libsonnet';
{
  /*
   A publicly-visible bucket.
   This is intended for use by itself or as a field value in an MergedOut.
   It should not be combined with other PublicBucket objects, because that
   causes name clashes.
   */
  PublicBucket: tf.MergedOut {
    local cfg = self.cfg,
    local top = self,
    bucket: tf.ResourceBase {
      type: 'aws_s3_bucket',
      name: cfg.name,
      arguments: {
        bucket: cfg.bucket_name,
        tags: { Name: cfg.name },
      },
      [if std.member(std.get(cfg, 'import', []), 'bucket') then 'import_id']:
        top.bucket.arguments.bucket,
    },
    ownership_controls: tf.ResourceBase {
      type: 'aws_s3_bucket_ownership_controls',
      name: cfg.name,
      arguments: {
        bucket: top.bucket.id,
        rule: { object_ownership: 'BucketOwnerPreferred' },
      },
    },
    public_access_block: tf.ResourceBase {
      type: 'aws_s3_bucket_public_access_block',
      name: cfg.name,
      arguments: {
        bucket: top.bucket.id,
        block_public_acls: false,
        block_public_policy: false,
        ignore_public_acls: false,
        restrict_public_buckets: false,
      },
    },
    acl: tf.ResourceBase {
      type: 'aws_s3_bucket_acl',
      name: cfg.name,
      arguments: {
        bucket: top.bucket.id,
        acl: 'public-read',
        depends_on: {
          dependencies: [
            top.ownership_controls,
            top.public_access_block,
          ],
          out: [d.path.content for d in self.dependencies],
        },
      },
    },
  },

  // Enhance a PublicBucket with website configuration.
  // routing_rules can be supplied, and index_document can be overwritten.
  WebsiteConfig: {
    local top = self,
    cfg+:: {
      // I mean, this just makes sense, right?
      index_document: { suffix: 'index.html' },
    },
    local cfg = self.cfg,
    website_config: tf.ResourceBase {
      type: 'aws_s3_bucket_website_configuration',
      name: cfg.name,
      arguments: {
        bucket: top.bucket.id,
        index_document: cfg.index_document,
        [if std.objectHas(cfg, 'routing_rule') then 'routing_rule']:
          cfg.routing_rule,
      },
    },
  },
  // Base DNS for a simple domain, with a zone and a single A record.
  // This A record in incomplete so that it can vary between BucketDNS and
  // CloudFrontDNS
  BaseDNS: tf.MergedOut {
    local top = self,
    dns_zone: tf.ResourceBase {
      name: top.cfg.name,
      type: 'aws_route53_zone',
      arguments: { name: top.cfg.bucket_name },
    },
    dns_record: tf.ResourceBase {
      name: top.cfg.name,
      type: 'aws_route53_record',
      arguments: {
        name: top.cfg.bucket_name,
        zone_id: top.dns_zone.id,
        type: 'A',
      },
    },
  },
  /// DNS for a simple domain with a single A record aliased to the S3 bucket.
  BucketDNS: self.BaseDNS {
    local top = self,
    dns_record+: {
      arguments+: {
        alias: tf.FieldsOut {
          evaluate_target_health: true,
          name: top.website_config.attr('website_domain'),
          zone_id: top.bucket.attr('hosted_zone_id'),
        },
      },
    },
  },
  BucketCert: {
    local top = self,
    tls_certificate: tf.ResourceBase {
      type: 'aws_acm_certificate',
      name: top.cfg.name,
      arguments: {
        domain_name: top.cfg.bucket_name,
        validation_method: 'DNS',
        lifecycle: { create_before_destroy: true },
      },
    },
  },
  BucketCloudFront: {
    local top = self,
    cloudfront_distro: tf.ResourceBase {
      name: top.cfg.name,
      type: 'aws_cloudfront_distribution',
      arguments: {
        aliases: [top.cfg.bucket_name],
        default_cache_behavior: tf.FieldsOut {
          forwarded_values: {
            query_string: true,
            cookies: { forward: 'all' },
          },
          viewer_protocol_policy: 'allow-all',
          cached_methods: self.allowed_methods,
          allowed_methods: ['GET', 'HEAD', 'OPTIONS'],
          target_origin_id: top.bucket.attr('bucket_regional_domain_name'),
        },
        enabled: true,
        is_ipv6_enabled: true,
        origin: tf.FieldsOut {
          custom_origin_config: {
            http_port: 80,
            https_port: 443,
            origin_keepalive_timeout: 5,
            origin_protocol_policy: 'http-only',
            origin_read_timeout: 30,
            origin_ssl_protocols: ['SSLv3', 'TLSv1', 'TLSv1.1', 'TLSv1.2'],
          },
          origin_id: top.bucket.attr('bucket_regional_domain_name'),
          domain_name: top.website_config.attr('website_endpoint'),
        },
        restrictions: {
          geo_restriction: { restriction_type: 'none', locations: [] },
        },
        viewer_certificate: tf.FieldsOut {
          acm_certificate_arn: top.tls_certificate.attr('arn'),
          cloudfront_default_certificate: false,
          ssl_support_method: 'sni-only',
        },
      },
    },
  },
  // DNS for a simple domain with a single A record aliased to a CloudFront
  // distro.
  // A CNAME record, used to validate SSL certs, is also supplied.
  CloudFrontDNS: self.BaseDNS {
    local top = self,
    dns_record+: {
      arguments+: {
        alias: tf.FieldsOut {
          evaluate_target_health: true,
          name: top.cloudfront_distro.attr('domain_name'),
          zone_id: top.cloudfront_distro.attr('hosted_zone_id'),
        },
      },
    },
    // A DNS record used to validate a TLS certificate.
    // It proves ownership of this domain.
    tls_dns_record: tf.ResourceBase {
      type: 'aws_route53_record',
      name: top.cfg.name + '_validation_record',
      arguments: {
        for_each: tf.TemplateStringBase {
          content:
            // This generates a map of domain_name to object.
            // objects cannot be in sets, only maps.
            // It seems like they probably can't be keys.
            '{for dvo in %(dvo)s : dvo.domain_name => dvo}' % {
              dvo: top.tls_certificate.attr(
                'domain_validation_options'
              ).content,
            },
        },
        allow_overwrite: true,
        name: tf.TemplateStringBase {
          content: 'each.value.resource_record_name',
        },
        type: tf.TemplateStringBase {
          content: 'each.value.resource_record_type',
        },
        records: [
          tf.TemplateStringBase {
            content: 'each.value.resource_record_value',
          }.out,
        ],
        zone_id: top.dns_zone.attr('zone_id'),
        ttl: 60,
      },
    },
  },
}
