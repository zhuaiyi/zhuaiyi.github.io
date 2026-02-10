#!/usr/bin/env ruby
#
# Check for changed posts

Jekyll::Hooks.register :posts, :post_init do |post|
  next unless post.path
  commit_num = `git rev-list --count HEAD "#{ post.path }" 2>/dev/null`.strip
  next if commit_num.empty? || commit_num.to_i <= 1
  lastmod_date = `git log -1 --pretty="%ad" --date=iso "#{ post.path }" 2>/dev/null`.strip
  post.data['last_modified_at'] = lastmod_date if lastmod_date && !lastmod_date.empty?
end
