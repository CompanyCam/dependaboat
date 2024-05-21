require "minitest/autorun"
require "dependaboat"

class AssigneesTest < Minitest::Test
  def test_assignees
    cli = Dependaboat::Cli.new
    cli.send(:load_config, "test/full_config.yaml")

    assert_equal ["test_user_npm", "test_user_all"], cli.send(:assignees_for_ecosystem, "npm")
    assert_equal ["test_user_rubygems_1", "test_user_rubygems_2", "test_user_all"], cli.send(:assignees_for_ecosystem, "rubygems")
    assert_equal ["test_user_other", "test_user_all"], cli.send(:assignees_for_ecosystem, "docker")
  end

  def test_empty_assignees
    cli = Dependaboat::Cli.new
    cli.send(:load_config,"test/no_assignees_config.yaml")

    assert_equal [], cli.send(:assignees_for_ecosystem, "rubygems")
  end
end
