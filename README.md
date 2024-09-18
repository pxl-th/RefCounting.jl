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
    x = RefCounted(Ref(1), dtor)
    return
  end
  ```
    
  </td>
  <td>
    
  ```julia
  function f()
    x = RefCounted(Ref(1), dtor)
    decrement!(x)
    return
  end
  ```

  </td>
</tr>
</table>
