-- Runs on every server: hands the panel what neofetch says about it.
-- --stdout is plain text, without the logo and colour codes.
beacle.on("info", function()
  local out, code, err = beacle.exec("neofetch", { "--stdout" }, { timeout = 15 })
  if not out then
    return { error = code } -- neofetch is not installed, or did not finish
  end
  if code ~= 0 then
    return { error = "neofetch exited " .. code .. ": " .. (err or "") }
  end
  return { text = out }
end)
