# RefCounting.jl

Reference Counting Garbage Collection for Julia.

<table>
<tr>
  <td>Before RC pass</td>
  <td>After RC pass</td>
</tr>

<tr>
  <td>
    
  ```julia
  function f()
    x = RefCounted(1)
    return
  end
  ```
    
  </td>
  <td>
    
  ```julia
  function f()
    x = RefCounted(1)
    decrement!(x)
    return
  end
  ```

  </td>
</tr>
</table>
